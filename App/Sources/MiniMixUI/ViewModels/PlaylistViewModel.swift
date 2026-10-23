import Core
import Foundation
import Observation

/// Panel de playlist (T51). Edita la `Playlist` del proyecto y conduce un `PlaylistSequencing`
/// inyectado por entrada. El transporte va por `Command` (`play`, `playlistNext`, …).
@MainActor @Observable
public final class PlaylistViewModel {
    private var sequencers: [InputID: any PlaylistSequencing] = [:]
    /// Reloj del item actual de cada playlist.
    private var itemClocks: [InputID: PlaybackInfo] = [:]
    @ObservationIgnored private let makeSequencer: @MainActor (Playlist) -> any PlaylistSequencing
    @ObservationIgnored weak var app: AppViewModel?

    init(makeSequencer: @escaping @MainActor (Playlist) -> any PlaylistSequencing) {
        self.makeSequencer = makeSequencer
    }

    // MARK: Registro

    func reset(for project: Project) {
        sequencers = [:]
        itemClocks = [:]
        for input in project.inputs {
            if let playlist = input.content.playlist { register(input.id, playlist: playlist) }
        }
    }

    func register(_ id: InputID, playlist: Playlist) { sequencers[id] = makeSequencer(playlist) }

    func unregister(_ id: InputID) {
        sequencers[id] = nil
        itemClocks[id] = nil
    }

    func sync(_ id: InputID, playlist: Playlist) { sequencers[id]?.playlist = playlist }

    // MARK: Consultas

    public func playlist(for id: InputID) -> Playlist? { app?.descriptor(id)?.content.playlist }

    public func state(for id: InputID) -> SequencerState { sequencers[id]?.state ?? .idle }

    /// Índice (en `playlist.items`) del item actual, si lo hay.
    public func currentIndex(for id: InputID) -> Int? {
        switch state(for: id) {
        case .playing(let index), .held(let index, _): index
        case .idle, .ended: nil
        }
    }

    /// Índice del item siguiente (precarga), si lo hay.
    public func nextIndex(for id: InputID) -> Int? {
        if case .held(_, let cued) = state(for: id) { return cued }
        return sequencers[id]?.upcomingIndex
    }

    public func isHeld(_ id: InputID) -> Bool {
        if case .held = state(for: id) { return true }
        return false
    }

    /// Duración útil de un item (con recortes), si se conoce.
    public func duration(of item: PlaylistItem) -> Double? {
        if item.source.isStill { return item.duration ?? PlaylistItem.defaultStillDuration }
        if let duration = item.duration { return duration }
        let full = item.source.mediaReference.flatMap { app?.mediaDurations[$0.path] }
        guard let end = item.outPoint ?? full else { return nil }
        return max(0, end - (item.inPoint ?? 0))
    }

    public func itemElapsed(for id: InputID) -> Double {
        itemClocks[id]?.elapsed(at: app?.now ?? 0) ?? 0
    }

    /// Tiempo restante del item actual.
    public func itemRemaining(for id: InputID) -> Double? {
        guard let index = currentIndex(for: id), let item = playlist(for: id)?.items[safe: index],
              let total = duration(of: item) else { return nil }
        return isHeld(id) ? 0 : max(0, total - itemElapsed(for: id))
    }

    /// Tiempo restante de la playlist: item actual + items habilitados posteriores (sin bucle).
    public func playlistRemaining(for id: InputID) -> Double? {
        guard let playlist = playlist(for: id) else { return nil }
        let start: Int
        var total: Double = 0
        if let current = currentIndex(for: id) {
            guard let left = itemRemaining(for: id) else { return nil }
            total = left
            start = current + 1
        } else {
            start = 0
        }
        for item in playlist.items.dropFirst(start) where item.enabled {
            guard let seconds = duration(of: item) else { return nil }
            total += seconds
        }
        return total
    }

    // MARK: Transporte (→ Command)

    public func togglePlay(_ id: InputID) {
        guard let app else { return }
        app.send(app.isPlaying(id) ? .pause(id) : .play(id))
    }

    public func next(_ id: InputID) { app?.send(.playlistNext(id)) }
    public func previous(_ id: InputID) { app?.send(.playlistPrevious(id)) }
    public func restartItem(_ id: InputID) { app?.send(.restart(id)) }
    public func jump(_ id: InputID, to item: ItemID) { app?.send(.playlistJump(id, item)) }

    // MARK: Desde el despachador

    func handle(_ event: SequencerEvent, for id: InputID) {
        guard var sequencer = sequencers[id] else { return }
        let before = sequencer.state
        let after = sequencer.handle(event)
        sequencers[id] = sequencer
        let now = app?.now ?? 0
        let playing = app?.isPlaying(id) ?? false
        switch after {
        case .playing:
            if before != after || event == .restartItem || event == .play {
                var clock = PlaybackInfo()
                if playing { clock.play(at: now) } else { clock.state = .paused }
                itemClocks[id] = clock
            }
        case .held, .idle:
            itemClocks[id, default: PlaybackInfo()].pause(at: now)
            if case .held = after, app?.playback[id] != nil {
                app?.playback[id]?.pause(at: now)
                app?.playback[id]?.state = .held
            }
        case .ended:
            itemClocks[id] = nil
            app?.playback[id]?.end(at: now)
        }
    }

    func pauseClock(for id: InputID) {
        itemClocks[id]?.pause(at: app?.now ?? 0)
    }

    func resumeClock(for id: InputID) {
        guard case .playing = state(for: id) else { return }
        itemClocks[id]?.play(at: app?.now ?? 0)
    }

    /// Fase de mocks: emula el fin de item que en T80 llega de la fuente (`SourceEvent`).
    func simulateItemEnd(for id: InputID) {
        guard case .playing = state(for: id), let left = itemRemaining(for: id), left <= 0 else { return }
        handle(.itemEnded, for: id)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
