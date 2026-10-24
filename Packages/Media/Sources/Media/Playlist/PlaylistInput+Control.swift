import Core
import Foundation
import Metal

// Lógica de control. Todo lo de este archivo corre en `queue` (serie); el estado se
// modifica con secciones cortas de `state.withLock` y los efectos (play/pause de las
// fuentes, audio) se aplican fuera del cerrojo.
extension PlaylistInput {
    var referenceTime: HostTime { state.withLock { $0.lastTick } ?? environment.clock.now }

    // MARK: Tick

    func step(at time: HostTime) {
        let frame = environment.clock.frameRate.frameDuration
        let prepared = state.withLock { s -> Bool in
            s.lastTick = time
            s.frameDuration = frame
            return s.prepared
        }
        guard prepared else { return }
        connectAudio()
        if let pending = state.withLock({ $0.pending }), time.seconds >= pending.at.seconds - frame / 2 {
            commit(pending)
        }
        if let end = state.withLock({ $0.fadeEnd }) {
            if time.seconds >= end.seconds - frame / 2 { finishFade() } else { updateFadeGains(at: time) }
        }
        let (seqState, active, idle) = state.withLock { s in
            (s.sequencer.state, s.active, s.pending == nil && s.fadeEnd == nil && !s.timelineFrozen)
        }
        if case .playing(let index) = seqState {
            if active?.index != index {
                navigateStep(to: index, at: time)
            } else if let active, active.ready, !active.started {
                begin(at: time, fromStart: false)
            } else if idle {
                checkEnd(at: time)
            }
        }
        preloadIfNeeded(at: time)
    }

    /// Primer tick de la rejilla (`time` + k·F) en o después de `instant`.
    static func gridTick(_ instant: Double, after time: HostTime, frame: Double) -> HostTime {
        guard instant > time.seconds else { return time }
        return time + ((instant - time.seconds) / frame - 1e-3).rounded(.up) * frame
    }

    /// Programa el siguiente cambio cuando el fin del item cae en el próximo tick.
    private func checkEnd(at time: HostTime) {
        let frame = environment.clock.frameRate.frameDuration
        let snapshot = state.withLock { s -> (Slot, Double, SequencerState, Slot?)? in
            guard let active = s.active, active.ready, active.started, let duration = active.duration else { return nil }
            var probe = s.sequencer
            return (active, duration, probe.handle(.itemEnded), s.standby)
        }
        guard let (active, duration, after, standby) = snapshot else { return }
        // Vídeo: posición del reproductor ahora (reloj del host); el resto, por ticks.
        let base = active.isVideo ? HostClock.hostTime(nanos: HostClock.nowNanos()) : time
        let endHost = base.seconds + max(0, duration - elapsed(of: active, at: time))
        switch after {
        case .playing(let next):
            let fade = fadeDuration(outgoing: active, incoming: standby?.index == next ? standby : nil)
            let start = Self.gridTick(endHost - fade, after: time, frame: frame)
            guard start.seconds <= time.seconds + frame * 1.5 else { return }
            guard let standby, standby.index == next, standby.ready else {
                if endHost <= time.seconds + frame / 2 { markLate(itemIndex: next) }
                return
            }
            let at = start.seconds <= time.seconds + frame / 2 ? time + frame : start
            arm(standby, at: at, fade: fade)
        case .held, .ended:
            let at = Self.gridTick(endHost, after: time, frame: frame)
            guard at.seconds <= time.seconds + frame * 1.5 else { return }
            let pending = Pending(at: at, kind: after == .ended ? .end : .hold)
            if at.seconds <= time.seconds + frame / 2 {
                commit(pending)
            } else {
                state.withLock { $0.pending = pending }
            }
        case .idle:
            break
        }
    }

    private func markLate(itemIndex: Int) {
        let first = state.withLock { s -> Bool in
            defer { s.lateMarked = true }
            if !s.lateMarked { s.stats.lateSwitches += 1 }
            return !s.lateMarked
        }
        if first {
            logger.warning("Playlist \(self.id): el item \(itemIndex) no está listo al final del actual; se mantiene el último fotograma")
        }
    }

    /// Duración del fundido redondeada a fotogramas (0 = corte).
    private func fadeDuration(outgoing: Slot, incoming: Slot?) -> Double {
        let (transition, frame) = state.withLock { ($0.sequencer.playlist.itemTransition, $0.frameDuration) }
        guard case .fade(let seconds) = transition, seconds > 0 else { return 0 }
        var limit = min(seconds, 2)
        if let duration = outgoing.duration { limit = min(limit, duration) }
        if let duration = incoming?.duration { limit = min(limit, duration) }
        return (limit / frame).rounded(.down) * frame
    }

    private func arm(_ incoming: Slot, at: HostTime, fade: Double) {
        let previous = state.withLock { $0.shown }
        let visual = visual(for: incoming, previous: previous)
        let id = state.withLock { s -> Int in
            if fade > 0 {
                s.fade = Fade(from: previous ?? .black, to: visual, start: at, duration: fade)
                s.pending = Pending(at: at, kind: .fade(fade))
            } else {
                s.armed = (visual, at)
                s.pending = Pending(at: at, kind: .cut(visual))
            }
            s.armID += 1
            s.scheduledPlay = s.armID
            return s.armID
        }
        // Vídeo: arrancar medio fotograma (del lienzo o del clip) antes del tick del cambio,
        // para que su fotograma 0 sea el que se pide en ese tick.
        guard let video = incoming.source as? VideoInput else { return }
        let canvasFrame = environment.clock.frameRate.frameDuration
        let fps = video.stats.nominalFrameRate
        let lead = min(canvasFrame, fps > 0 ? 1 / fps : canvasFrame) / 2
        let deadline = DispatchTime(uptimeNanoseconds: UInt64(max(0, HostClock.nanos(at + -lead))))
        queue.asyncAfter(deadline: deadline) { [weak self] in self?.firePlay(id) }
    }

    private func firePlay(_ id: Int) {
        let source = state.withLock { s -> FrameSource? in
            guard s.scheduledPlay == id else { return nil }
            s.scheduledPlay = nil
            return s.standby?.source ?? s.active?.source
        }
        source?.play()
    }

    // MARK: Commit

    private func commit(_ pending: Pending) {
        switch pending.kind {
        case .cut, .fade:
            commitSwitch(pending)
        case .hold, .end:
            let (source, ended) = state.withLock { s -> (FrameSource?, Bool) in
                s.pending = nil
                s.armed = nil
                let result = s.sequencer.handle(.itemEnded)
                let hold = s.sequencer.playlist.holdBehavior
                if var slot = s.active {
                    slot.elapsedBase = slot.duration ?? slot.elapsedBase
                    slot.runningSince = nil
                    s.active = slot
                }
                switch (result, hold) {
                case (.ended, .lastFrame), (.held, .lastFrame): break
                case (.held, .nextFirstFrame): if let standby = s.standby, standby.ready { s.shown = .source(standby.source) }
                default: s.shown = .black
                }
                return (s.active?.source, result == .ended)
            }
            source?.pause()
            if ended {
                continuation.yield(.itemChanged(nil))
                continuation.yield(.ended)
            }
        }
    }

    private func commitSwitch(_ pending: Pending) {
        let result = state.withLock { s -> (old: Slot?, new: Slot, play: Bool)? in
            s.pending = nil
            guard let incoming = s.standby else { return nil }
            s.sequencer.handle(.itemEnded)
            let play = s.scheduledPlay != nil || !incoming.isVideo
            s.scheduledPlay = nil
            var slot = incoming
            slot.started = true
            slot.elapsedBase = 0
            slot.runningSince = s.timelineFrozen ? nil : pending.at
            let old = s.active
            s.active = slot
            s.standby = nil
            s.lateMarked = false
            s.stats.switches += 1
            switch pending.kind {
            case .cut(let visual):
                s.shown = visual
                s.armed = nil
            case .fade(let duration):
                s.shown = s.fade?.to
                s.outgoing = old
                s.fadeEnd = pending.at + duration
            case .hold, .end:
                break
            }
            return (old, slot, play)
        }
        guard let result else { return }
        if result.play { result.new.source.play() }
        if case .cut = pending.kind {
            if let node = (result.new.source as? AudioSource)?.node { mixer.setGain(1, for: node) }
            if let old = result.old { release(old, delayed: true) }
        }
        emitStarted(result.new)
    }

    func finishFade() {
        let (outgoing, active) = state.withLock { s -> (Slot?, Slot?) in
            defer {
                s.outgoing = nil
                s.fadeEnd = nil
                s.fade = nil
            }
            return (s.outgoing, s.active)
        }
        renderer.endComposite()
        if let node = (active?.source as? AudioSource)?.node { mixer.setGain(1, for: node) }
        if let outgoing { release(outgoing, delayed: true) }
    }

    private func updateFadeGains(at time: HostTime) {
        let snapshot = state.withLock { s -> (FrameSource?, FrameSource?, Double)? in
            guard let fade = s.fade else { return nil }
            return (s.outgoing?.source, s.active?.source, (time - fade.start) / fade.duration)
        }
        guard let (outgoing, incoming, progress) = snapshot else { return }
        let gains = TransitionCurve.audioGains(progress)
        if let node = (outgoing as? AudioSource)?.node { mixer.setGain(Float(gains.outgoing), for: node) }
        if let node = (incoming as? AudioSource)?.node { mixer.setGain(Float(gains.incoming), for: node) }
    }

    func emitStarted(_ slot: Slot) {
        continuation.yield(.itemChanged(slot.item.id))
        if let duration = slot.duration { continuation.yield(.durationKnown(duration)) }
    }

    // MARK: Visuales

    /// Visual de un item. Audio: negro, su cartela, o la última imagen visible (copiada en GPU
    /// para que sobreviva a la fuente saliente).
    func visual(for slot: Slot, previous: Visual?) -> Visual {
        guard case .audio = slot.item.source else { return .source(slot.source) }
        switch state.withLock({ $0.sequencer.playlist.audioItemVisual }) {
        case .black: return .black
        case .card: return .source(slot.source)
        case .lastImage:
            switch previous {
            case .texture(let texture)?: return .texture(texture)
            case .source(let source)?:
                guard let texture = source.texture(for: referenceTime), let copy = renderer.snapshot(texture) else { return .black }
                return .texture(copy)
            case .black?, nil: return .black
            }
        }
    }
}
