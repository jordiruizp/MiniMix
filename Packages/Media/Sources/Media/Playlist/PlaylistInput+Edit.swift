import Core
import Foundation

// Edición en vivo de la playlist (en `queue`).
extension PlaylistInput {
    func applyEdit(_ playlist: Playlist) {
        let frame = environment.clock.frameRate.frameDuration
        // Un cambio ya programado se basa en la playlist anterior: se cancela y `checkEnd` lo
        // vuelve a programar en el siguiente tick con la nueva.
        if state.withLock({ $0.pending != nil }) { cancelTransition() }
        let edit = state.withLock { s -> (changed: [PlaylistItem], wasEnded: Bool)? in
            let old = s.sequencer.playlist
            guard old != playlist else { return nil }
            let changed = playlist.items.filter { item in old.items.first(where: { $0.id == item.id }) != item }
            changed.forEach { s.knownDurations[$0.id] = nil }
            let wasEnded = s.sequencer.state == .ended
            s.sequencer.playlist = playlist
            s.active = Self.remap(s.active, in: playlist, frame: frame)
            s.outgoing = Self.remap(s.outgoing, in: playlist, frame: frame)
            return (changed, wasEnded)
        }
        guard let edit else { return }
        dropStaleStandby(in: playlist, frame: frame)
        // La edición terminó la playlist (se eliminó el item actual y no hay sucesor).
        if !edit.wasEnded, state.withLock({ $0.sequencer.state == .ended }) {
            state.withLock { $0.active?.source }?.pause()
            continuation.yield(.itemChanged(nil))
            continuation.yield(.ended)
        }
        // Solo se sondean los items nuevos o cambiados.
        if !edit.changed.isEmpty { probeDurations(edit.changed) }
    }

    /// La ranura de espera vale si sigue siendo el siguiente item, o el nuevo actual (se eliminó
    /// el que sonaba y su sucesor es justo el precargado), y con el mismo medio.
    private func dropStaleStandby(in playlist: Playlist, frame: Double) {
        let stale = state.withLock { s -> Slot? in
            guard let standby = s.standby else { return nil }
            let remapped = Self.remap(standby, in: playlist, frame: frame)
            if let remapped, remapped.index >= 0,
               remapped.index == s.sequencer.upcomingIndex
                || (remapped.index == s.sequencer.currentIndex && s.active?.index != remapped.index) {
                s.standby = remapped
                return nil
            }
            s.standby = nil
            return standby
        }
        guard let stale else { return }
        let active = state.withLock { $0.active }
        let replacement = active.map { visual(for: $0, previous: nil) } ?? .black
        let displayed = state.withLock { s -> Bool in
            let displayed = Self.shows(s.shown, stale.source) || Self.shows(s.fallback, stale.source)
            if displayed {
                s.shown = replacement
                s.fallback = nil
            }
            return displayed
        }
        release(stale, delayed: displayed)
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
