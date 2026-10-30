import Core
import Foundation

// Edición en vivo de la playlist (en `queue`).
extension PlaylistInput {
    func applyEdit(_ playlist: Playlist) {
        let frame = environment.clock.frameRate.frameDuration
        let changed = state.withLock { s -> Bool in
            let old = s.sequencer.playlist
            guard old != playlist else { return false }
            for item in playlist.items where old.items.first(where: { $0.id == item.id }) != item {
                s.knownDurations[item.id] = nil
            }
            s.sequencer.playlist = playlist
            s.active = Self.remap(s.active, in: playlist, frame: frame)
            s.outgoing = Self.remap(s.outgoing, in: playlist, frame: frame)
            return true
        }
        guard changed else { return }
        // La ranura de espera solo vale si sigue siendo el siguiente item y con el mismo medio.
        let stale = state.withLock { s -> Slot? in
            guard let standby = s.standby else { return nil }
            let remapped = Self.remap(standby, in: playlist, frame: frame)
            if let remapped, remapped.index >= 0, remapped.index == s.sequencer.upcomingIndex {
                s.standby = remapped
                return nil
            }
            return standby
        }
        if let stale {
            cancelTransition()
            let displayed = state.withLock { s -> Bool in
                s.standby = nil
                let displayed = Self.shows(s.shown, stale.source) || Self.shows(s.fallback, stale.source)
                if displayed, let active = s.active { s.shown = .source(active.source) }
                return displayed
            }
            release(stale, delayed: displayed)
        }
        probeDurations(playlist)
    }

    /// Ranura con el índice y los datos nuevos de su item. Índice -1 si el item ya no está o
    /// cambió de medio/In/Out: el control lo trata como «no es el actual» y carga el que toque.
    static func remap(_ slot: Slot?, in playlist: Playlist, frame: Double) -> Slot? {
        guard let slot else { return nil }
        guard let index = playlist.items.firstIndex(where: { $0.id == slot.item.id }) else {
            return Slot(index: -1, item: slot.item, source: slot.source, ready: slot.ready, started: slot.started,
                        duration: slot.duration, elapsedBase: slot.elapsedBase, runningSince: slot.runningSince)
        }
        let item = playlist.items[index]
        let sameMedia = item.source == slot.item.source && item.inPoint == slot.item.inPoint
            && item.outPoint == slot.item.outPoint
        var updated = Slot(index: sameMedia ? index : -1, item: sameMedia ? item : slot.item, source: slot.source,
                           ready: slot.ready, started: slot.started, duration: slot.duration,
                           elapsedBase: slot.elapsedBase, runningSince: slot.runningSince)
        if sameMedia, slot.ready { updated.duration = duration(of: updated, frame: frame) ?? slot.duration }
        return updated
    }
}
