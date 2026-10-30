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
        struct Snapshot {
            let active: Slot
            let duration: Double
            let after: SequencerState
            let standby: Slot?
        }
        let snapshot = state.withLock { s -> Snapshot? in
            guard let active = s.active, active.ready, active.started, let duration = active.duration else { return nil }
            var probe = s.sequencer
            return Snapshot(active: active, duration: duration, after: probe.handle(.itemEnded), standby: s.standby)
        }
        guard let snapshot else { return }
        let (active, after, standby) = (snapshot.active, snapshot.after, snapshot.standby)
        let duration = snapshot.duration
        // Vídeo: posición del reproductor ahora (reloj del host); el resto, por ticks.
        let base = active.isVideo ? HostClock.hostTime(nanos: HostClock.nowNanos()) : time
        let endHost = base.seconds + max(0, duration - elapsed(of: active, at: time))
        switch after {
        case .playing(let next):
            let fade = fadeDuration(outgoing: active, incoming: standby?.index == next ? standby : nil)
            let start = Self.gridTick(endHost - fade, after: time, frame: frame)
            if let standby, standby.index == next, standby.ready { scheduleStart(of: standby, at: start, now: time) }
            guard start.seconds <= time.seconds + frame * 1.5 else { return }
            guard let standby, standby.index == next, standby.ready else {
                if endHost <= time.seconds + frame / 2 { markLate(itemIndex: next) }
                return
            }
            let at = start.seconds <= time.seconds + frame / 2 ? time + frame : start
            arm(standby, at: at, fade: fade)
        case .held, .ended:
            scheduleStop(endHost: endHost, ended: after == .ended, at: time, frame: frame)
        case .idle:
            break
        }
    }

    /// Fin sin siguiente que arrancar (held o ended): en el tick del final.
    private func scheduleStop(endHost: Double, ended: Bool, at time: HostTime, frame: Double) {
        let at = Self.gridTick(endHost, after: time, frame: frame)
        guard at.seconds <= time.seconds + frame * 1.5 else { return }
        let pending = Pending(at: at, kind: ended ? .end : .hold)
        if at.seconds <= time.seconds + frame / 2 {
            commit(pending)
        } else {
            state.withLock { $0.pending = pending }
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
        state.withLock { s in
            if fade > 0 {
                s.fade = Fade(from: previous ?? .black, to: visual, start: at, duration: fade)
                s.pending = Pending(at: at, kind: .fade(fade))
            } else {
                s.armed = (visual, at)
                s.pending = Pending(at: at, kind: .cut(visual))
            }
        }
        // Sin arranque anticipado (precarga tardía): medio fotograma antes del cambio.
        scheduleStart(of: incoming, at: at, now: nil)
    }

    /// Programa el `play()` del vídeo entrante para que su fotograma 0 esté en pantalla en el
    /// tick `at`: medio fotograma (del clip) antes, más la latencia de arranque de AVPlayer estimada
    /// (media móvil de las medidas; ~250 ms en frío en MacBook Neo). Con `now` solo programa
    /// si ya toca (falta menos que esa latencia + 2 ticks); sin `now`, siempre.
    private func scheduleStart(of incoming: Slot, at: HostTime, now: HostTime?) {
        guard let video = incoming.source as? VideoInput else { return }
        let canvasFrame = environment.clock.frameRate.frameDuration
        let fps = video.stats.nominalFrameRate
        // Medio fotograma del clip: máximo margen frente al error de la estimación.
        let lead = (fps > 0 ? 1 / fps : canvasFrame) / 2
        let key = ObjectIdentifier(video)
        let schedule = state.withLock { s -> (id: Int, latency: Double)? in
            guard s.scheduledSource != key else { return nil }
            let latency = now == nil ? 0 : s.startLatency
            if let now, at.seconds - now.seconds > latency + lead + 2 * canvasFrame { return nil }
            s.armID += 1
            s.scheduledPlay = s.armID
            s.scheduledSource = key
            return (s.armID, latency)
        }
        guard let schedule else { return }
        let fireAt = at + -(lead + schedule.latency)
        let deadline = DispatchTime(uptimeNanoseconds: UInt64(max(0, HostClock.nanos(fireAt))))
        queue.asyncAfter(deadline: deadline) { [weak self] in self?.firePlay(schedule.id) }
    }

    private func firePlay(_ id: Int) {
        let source = state.withLock { s -> FrameSource? in
            guard s.scheduledPlay == id else { return nil }
            s.scheduledPlay = nil
            return s.standby?.source ?? s.active?.source
        }
        guard let source else { return }
        source.play()
        measureStartLatency(of: source)
    }

    /// Mide cuánto tarda el reproductor en mover su posición tras `play()` y actualiza la
    /// estimación (la primera medida sustituye al valor inicial; después, media móvil acotada a 0…0,5 s).
    private func measureStartLatency(of source: FrameSource) {
        guard source is VideoInput else { return }
        let origin = source.currentTime ?? 0
        let started = HostClock.nowNanos()
        Task.detached(priority: .high) { [weak self] in
            while HostClock.nowNanos() - started < 1_000_000_000 {
                if let position = source.currentTime, position > origin + 0.0005 {
                    // La posición ya avanzó `position - origin` desde que arrancó.
                    let latency = Double(HostClock.nowNanos() - started) / 1e9 - (position - origin)
                    self?.state.withLock { s in
                        let blended = s.stats.lastStartLatency == nil ? latency : 0.5 * s.startLatency + 0.5 * latency
                        s.startLatency = min(0.5, max(0, blended))
                        s.stats.lastStartLatency = latency
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
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
        struct Switched {
            let old: Slot?
            let new: Slot
            let play: Bool
        }
        let result = state.withLock { s -> Switched? in
            s.pending = nil
            guard let incoming = s.standby else { return nil }
            s.sequencer.handle(.itemEnded)
            let play = s.scheduledPlay != nil || !incoming.isVideo
            s.scheduledPlay = nil
            s.scheduledSource = nil
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
                s.fallback = s.shown
                s.shown = visual
                s.armed = nil
            case .fade(let duration):
                s.shown = s.fade?.to
                s.outgoing = old
                s.fadeEnd = pending.at + duration
            case .hold, .end:
                break
            }
            return Switched(old: old, new: slot, play: play)
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
                if let from = s.fade?.from { s.fallback = from }
                s.fade = nil
            }
            return (s.outgoing, s.active)
        }
        renderer.endComposite()
        if let node = (active?.source as? AudioSource)?.node { mixer.setGain(1, for: node) }
        if let outgoing { release(outgoing, delayed: true) }
    }

    private func updateFadeGains(at time: HostTime) {
        let snapshot = state.withLock { s -> (sources: [FrameSource?], progress: Double)? in
            guard let fade = s.fade else { return nil }
            return ([s.outgoing?.source, s.active?.source], (time - fade.start) / fade.duration)
        }
        guard let snapshot else { return }
        let (outgoing, incoming, progress) = (snapshot.sources[0], snapshot.sources[1], snapshot.progress)
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
