import Core
import Foundation

// Transporte, navegación manual, carga y liberación de ranuras (en `queue`).
extension PlaylistInput {
    // MARK: Transporte

    func handlePlay() {
        let (seqState, paused) = state.withLock { ($0.sequencer.state, $0.userPaused) }
        switch seqState {
        case .playing:
            guard paused else { return }
            let sources = state.withLock { s -> [FrameSource] in
                s.userPaused = false
                return [s.active, s.outgoing].compactMap { $0?.source }
            }
            sources.forEach { $0.play() }
            timelineFrozenChanged()
        case .idle, .ended, .held:
            navigate(.play)
        }
    }

    func handlePause() {
        let sources = state.withLock { s -> [FrameSource] in
            guard s.isPlaying, !s.userPaused else { return [] }
            s.userPaused = true
            return [s.active, s.outgoing].compactMap { $0?.source }
        }
        guard !sources.isEmpty else { return }
        sources.forEach { $0.pause() }
        timelineFrozenChanged()
    }

    func handleSeek(_ seconds: Double) {
        let time = referenceTime
        cancelTransition()
        let slot = state.withLock { s -> Slot? in
            guard var slot = s.active else { return nil }
            slot.elapsedBase = max(0, seconds)
            slot.runningSince = slot.runningSince == nil ? nil : time
            s.active = slot
            return slot
        }
        guard let slot, slot.isVideo || slot.source is AudioInput else { return }
        let target = (slot.item.inPoint ?? 0) + max(0, seconds)
        let source = slot.source
        Task { await source.seek(to: target) }
    }

    /// Pausa/oculta: congela el reloj de los items fijos y cancela cambios programados
    /// (un fundido en curso se completa al instante).
    func timelineFrozenChanged() {
        let time = referenceTime
        let frozen = state.withLock { s -> Bool in
            let frozen = s.timelineFrozen
            for keyPath in [\State.active, \State.outgoing] {
                guard var slot = s[keyPath: keyPath], slot.started else { continue }
                if frozen, let since = slot.runningSince {
                    slot.elapsedBase += max(0, time - since)
                    slot.runningSince = nil
                } else if !frozen, slot.runningSince == nil, s.isPlaying {
                    slot.runningSince = time
                }
                s[keyPath: keyPath] = slot
            }
            return frozen
        }
        if frozen { cancelTransition() }
    }

    // MARK: Navegación

    func navigate(_ event: SequencerEvent) {
        let time = referenceTime
        let outcome = state.withLock { s -> (index: Int, restart: Bool)? in
            let before = s.sequencer.currentIndex
            s.sequencer.handle(event)
            guard case .playing(let index) = s.sequencer.state else { return nil }
            s.userPaused = false
            let same = index == s.active?.index
            if same, s.sequencer.lastEventRestartsItem || before == nil || event == .play {
                return (index, true)
            }
            return same ? nil : (index, false)
        }
        guard let outcome else { return }
        cancelTransition()
        if outcome.restart {
            let started = state.withLock { $0.active?.started ?? false }
            begin(at: time, fromStart: started)
        } else {
            navigateStep(to: outcome.index, at: time)
        }
    }

    /// Lleva la ranura activa al item `index`: corte inmediato si está precargado; si no, lo carga.
    func navigateStep(to index: Int, at time: HostTime) {
        let (standby, prepared) = state.withLock { ($0.standby, $0.prepared) }
        guard prepared else { return }
        if let standby, standby.index == index {
            if standby.ready { cutNow(at: time) }
            return
        }
        if let standby {
            // Si se estaba viendo (held con nextFirstFrame), se pasa a ver el item activo y la
            // ranura se libera con retardo (la GPU puede estar leyéndola).
            let active = state.withLock { $0.active }
            let replacement = active.map { visual(for: $0, previous: nil) } ?? .black
            let displayed = state.withLock { s -> Bool in
                s.standby = nil
                let displayed = Self.shows(s.shown, standby.source) || Self.shows(s.fallback, standby.source)
                if displayed {
                    s.shown = replacement
                    s.fallback = nil
                }
                return displayed
            }
            release(standby, delayed: displayed)
        }
        if state.withLock({ $0.stats.loadedItems }) < 2 { _ = loadStandby(index) }
    }

    static func shows(_ visual: Visual?, _ source: FrameSource) -> Bool {
        if case .source(let shown)? = visual { return shown === source }
        return false
    }

    /// Corte manual al item de la ranura de espera (ya lista).
    private func cutNow(at time: HostTime) {
        let previous = state.withLock { $0.shown }
        guard let incoming = state.withLock({ $0.standby }) else { return }
        let visual = visual(for: incoming, previous: previous)
        let old = state.withLock { s -> Slot? in
            let old = s.active
            s.active = incoming
            s.standby = nil
            s.fallback = s.shown
            s.shown = visual
            s.stats.switches += 1
            s.lateMarked = false
            return old
        }
        if let old { release(old, delayed: true) }
        begin(at: time, fromStart: false)
    }

    /// Arranca (o reinicia) el item activo en `time` y avisa del cambio.
    func begin(at time: HostTime, fromStart: Bool) {
        let (current, previous) = state.withLock { ($0.active, $0.shown) }
        guard let current else { return }
        let visual = visual(for: current, previous: previous)
        let slot = state.withLock { s -> Slot? in
            guard var slot = s.active, slot.source === current.source else { return nil }
            slot.started = true
            slot.elapsedBase = 0
            slot.runningSince = s.timelineFrozen ? nil : time
            s.active = slot
            s.shown = visual
            return slot
        }
        guard let slot else { return }
        if let node = (slot.source as? AudioSource)?.node { mixer.setGain(1, for: node) }
        let source = slot.source
        if fromStart {
            Task {
                if let video = source as? VideoInput {
                    await video.restart()
                } else if let audio = source as? AudioInput {
                    await audio.restart()
                }
                source.play()
            }
        } else {
            source.play()
        }
        emitStarted(slot)
    }

    /// Cancela un cambio programado (y completa un fundido en curso).
    func cancelTransition() {
        let (flags, standby) = state.withLock { s -> (flags: [Bool], standby: Slot?) in
            let armed = s.pending != nil && (s.armed != nil || (s.fade != nil && s.fadeEnd == nil))
            if armed {
                s.armed = nil
                s.fade = nil
            }
            s.pending = nil
            s.scheduledPlay = nil
            s.scheduledSource = nil
            return ([armed, s.fadeEnd != nil], s.standby)
        }
        let (wasArmed, fading) = (flags[0], flags[1])
        if wasArmed { renderer.endComposite() }
        // El entrante pudo arrancar ya (arranque anticipado): volver a su In.
        if let standby, standby.source.playbackState == .playing {
            let source = standby.source
            source.pause()
            Task { await source.seek(to: standby.item.inPoint ?? 0) }
        }
        if fading { finishFade() }
    }

    // MARK: Carga

    /// Precarga el item `upcomingIndex` en la ranura libre (≤ 2 items cargados).
    func preloadIfNeeded(at time: HostTime) {
        // Decisión bajo el cerrojo; la posición del item (reproductor) se consulta fuera.
        let decision = state.withLock { s -> (target: Int, waitFor: Slot?)? in
            guard s.prepared, s.standby == nil, s.outgoing == nil, s.stats.loadedItems < 2,
                  let target = s.sequencer.upcomingIndex else { return nil }
            switch s.sequencer.state {
            case .playing(let index):
                guard let active = s.active, active.index == index, active.ready, active.started,
                      active.duration != nil else { return nil }
                return (target, active)
            case .held:
                return (target, nil)
            case .idle, .ended:
                return target == s.active?.index ? nil : (target, nil)
            }
        }
        guard let decision else { return }
        if let active = decision.waitFor, let duration = active.duration,
           duration - elapsed(of: active, at: time) > environment.preloadLead { return }
        _ = loadStandby(decision.target)
    }

    @discardableResult
    func loadStandby(_ index: Int) -> Bool {
        guard let source = createSlot(index: index, asActive: false) else { return false }
        Task {
            do {
                try await source.prepare()
                await Self.prewarm(source)
                self.enqueue { $0.loadFinished(source: source) }
            } catch {
                self.enqueue { $0.loadFailed(source: source, index: index, error: error) }
            }
        }
        return true
    }

    /// Crea la fuente del item `index` en una ranura (sin preparar). Cuenta como cargado.
    func createSlot(index: Int, asActive: Bool) -> FrameSource? {
        let (item, playlist, decoding) = state.withLock { s in
            (s.sequencer.playlist.items[index], s.sequencer.playlist, s.decodingEnabled)
        }
        // Nunca se cargan items deshabilitados (p. ej. uno que ya falló).
        guard item.enabled else { return nil }
        let source: FrameSource
        do {
            source = try (environment.itemFactory ?? environment.makeItemSource)(item, playlist)
        } catch {
            continuation.yield(.error("Item \(index + 1): \(error)"))
            disableFailedItem(index: index, id: item.id)
            return nil
        }
        if !decoding { (source as? DecodingControllable)?.setDecodingEnabled(false) }
        state.withLock { s in
            let slot = Slot(index: index, item: item, source: source)
            if asActive { s.active = slot } else { s.standby = slot }
            s.loading += 1
            s.stats.loadedItems += 1
            s.stats.createdItems += 1
            s.stats.maxLoadedItems = max(s.stats.maxLoadedItems, s.stats.loadedItems)
        }
        return source
    }

    func loadFinished(source: FrameSource) {
        let frame = environment.clock.frameRate.frameDuration
        let slot = state.withLock { s -> Slot? in
            s.loading -= 1
            let isActive = s.active?.source === source
            guard isActive || s.standby?.source === source,
                  var slot = isActive ? s.active : s.standby else { return nil }
            slot.ready = true
            slot.duration = Self.duration(of: slot, frame: frame)
            if let duration = slot.duration { s.knownDurations[slot.item.id] = duration }
            if isActive {
                s.active = slot
                if !s.prepared { s.prepared = true }
            } else {
                s.standby = slot
            }
            return slot
        }
        guard let slot else { return }
        let isActive = state.withLock { $0.active?.source === source }
        let previous = state.withLock { $0.shown }
        if isActive, previous == nil {
            let visual = visual(for: slot, previous: nil)
            state.withLock { $0.shown = visual }
        }
        state.withLock { s in
            if case .held = s.sequencer.state, !isActive, s.sequencer.playlist.holdBehavior == .nextFirstFrame {
                s.shown = .source(source)
            }
        }
        connectAudio()
    }

    func loadFailed(source: FrameSource, index: Int, error: Error) {
        let slot = state.withLock { s -> Slot? in
            s.loading -= 1
            if s.active?.source === source { defer { s.active = nil }; return s.active }
            if s.standby?.source === source { defer { s.standby = nil }; return s.standby }
            return nil
        }
        continuation.yield(.error("Item \(index + 1): \(error)"))
        if let slot {
            release(slot, delayed: false)
            disableFailedItem(index: index, id: slot.item.id)
        }
    }

    /// Un item que no carga se deshabilita en la copia de la playlist del secuenciador (se salta).
    private func disableFailedItem(index: Int, id: ItemID) {
        let stopped = state.withLock { s -> FrameSource?? in
            guard s.sequencer.playlist.items.indices.contains(index), s.sequencer.playlist.items[index].id == id else { return nil }
            s.sequencer.playlist.items[index].enabled = false
            guard s.sequencer.currentIndex == index else { return nil }
            // Era el destino de la navegación: al siguiente; si no lo hay, vuelta al item que
            // se está viendo; si tampoco, la playlist se detiene (idle).
            s.sequencer.handle(.next)
            guard s.sequencer.currentIndex == index else { return nil }
            if let active = s.active, active.index != index,
               s.sequencer.playlist.items.indices.contains(active.index),
               s.sequencer.playlist.items[active.index].enabled {
                s.sequencer.handle(.jump(active.item.id))
                if s.sequencer.currentIndex == active.index { return nil }
            }
            s.sequencer = PlaylistSequencer(playlist: s.sequencer.playlist)
            return .some(s.active?.source)
        }
        logger.error("Playlist \(self.id): item \(index + 1) no se pudo cargar; se salta")
        if let stopped {
            stopped?.pause()
            continuation.yield(.itemChanged(nil))
            continuation.yield(.ended)
        }
    }

    static func duration(of slot: Slot, frame: Double) -> Double? {
        let file: Double?
        switch slot.source {
        case let video as VideoInput: file = video.duration
        case let audio as AudioInput: file = audio.duration
        default:
            guard let still = slot.item.effectiveDuration else { return nil }
            return max(1, (still / frame).rounded()) * frame
        }
        return file.map { PlaylistEnvironment.effectiveMediaDuration(slot.item, fileDuration: $0) }
    }

    // MARK: Liberación y audio

    /// Libera una ranura: pausa, sin decodificar, fuera del mezclador. Si se estaba viendo,
    /// la referencia se suelta tras `releaseDelay` (la GPU puede estar leyendo su fotograma).
    func release(_ slot: Slot, delayed: Bool) {
        let source = slot.source
        source.pause()
        (source as? DecodingControllable)?.setDecodingEnabled(false)
        if let node = (source as? AudioSource)?.node { mixer.disconnect(node) }
        guard delayed else {
            state.withLock { $0.stats.loadedItems -= 1 }
            return
        }
        state.withLock { $0.releasing += 1 }
        queue.asyncAfter(deadline: .now() + environment.releaseDelay) { [weak self] in
            withExtendedLifetime(source) {}
            self?.state.withLock { s in
                s.stats.loadedItems -= 1
                s.releasing -= 1
            }
        }
    }

    /// Conecta al mezclador los nodos de audio de las ranuras listas (cuando E ya adjuntó `node`).
    func connectAudio() {
        guard mixer.node.engine != nil else { return }
        let slots = state.withLock { s -> [(FrameSource, Float)] in
            var list: [(FrameSource, Float)] = []
            if let active = s.active, active.ready { list.append((active.source, s.fade == nil || s.fadeEnd != nil ? 1 : 0)) }
            if let standby = s.standby, standby.ready { list.append((standby.source, 0)) }
            if let outgoing = s.outgoing { list.append((outgoing.source, 0)) }
            return list
        }
        for (source, gain) in slots {
            guard let node = (source as? AudioSource)?.node, !mixer.isConnected(node) else { continue }
            mixer.connect(node, gain: gain)
        }
    }
}
