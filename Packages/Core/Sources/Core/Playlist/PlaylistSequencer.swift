// Core/Playlist/PlaylistSequencer.swift — máquina de estados de la sección 6.3 (T12).
//
// Los índices refieren a `playlist.items` (los deshabilitados cuentan en la numeración).
// `next(i)` = siguiente habilitado tras i; si no hay, el primero habilitado si `loop` (puede
// ser el propio i: un único item en bucle se repite), si no nil. `previous(i)` es simétrico.
//
// Reglas (cubiertas por PlaylistSequencerTests):
// - play:      idle/ended → playing(primero habilitado) o ended si no hay ninguno;
//              held(i, cued: j) → playing(j) (j == nil → ended); playing → sin cambio.
// - itemEnded: solo en playing(i). continuous && !stopAfter → playing(next(i)) o ended;
//              stopAfterEach || stopAfter → held(i, cued: next(i)). En otros estados, sin cambio.
//              Si devuelve playing(i) (bucle de un item), el item debe reiniciarse.
// - next:      playing/held(i) → playing(next(i)); sin siguiente → sin cambio.
//              idle/ended → playing(primero habilitado).
// - previous:  playing/held(i) → playing(previous(i)); en el primero sin bucle reinicia
//              el item (playing(i)). idle → playing(primero); ended → playing(último habilitado).
// - jump(id):  → playing(k) si el item existe y está habilitado; si no, sin cambio.
// - restartItem: playing/held(i) → playing(i); idle/ended → sin cambio.
// - Edición de `playlist` mientras suena: el item actual se sigue por su `ItemID`. Si se movió,
//   el índice se actualiza; si se deshabilitó, sigue sonando (los saltos lo omiten); si se
//   eliminó: playing → el siguiente habilitado desde su antigua posición (con bucle) o ended;
//   held → ended. `cued` y `upcomingIndex` se recalculan siempre con la playlist actual.

import Foundation

public struct PlaylistSequencer: PlaylistSequencing {
    public var playlist: Playlist {
        didSet { reconcile(oldItems: oldValue.items) }
    }

    public private(set) var state: SequencerState = .idle

    public init(playlist: Playlist) {
        self.playlist = playlist
    }

    /// Item que sonará tras el actual (precarga A/B): playing(i) → next(i); held → cued;
    /// idle/ended → primero habilitado (lo que arrancaría play).
    public var upcomingIndex: Int? {
        switch state {
        case .idle, .ended: firstEnabled
        case .playing(let index): next(after: index)
        case .held(_, let cued): cued
        }
    }

    /// Índice del item actual (playing o held).
    public var currentIndex: Int? {
        switch state {
        case .playing(let index), .held(let index, _): index
        case .idle, .ended: nil
        }
    }

    /// Item actual (playing o held).
    public var currentItem: PlaylistItem? { currentIndex.map { playlist.items[$0] } }

    @discardableResult
    public mutating func handle(_ event: SequencerEvent) -> SequencerState {
        if let newState = transition(for: event) { state = newState }
        return state
    }

    // MARK: - Transiciones

    /// Nuevo estado o nil si el evento no cambia nada.
    private func transition(for event: SequencerEvent) -> SequencerState? {
        switch (event, state) {
        case (.play, .idle), (.play, .ended), (.next, .idle), (.next, .ended), (.previous, .idle):
            return playOrEnd(firstEnabled)
        case (.play, .held(_, let cued)):
            return playOrEnd(cued)
        case (.itemEnded, .playing(let index)):
            return afterItemEnded(index)
        case (.next, .playing(let index)), (.next, .held(let index, _)):
            return next(after: index).map { .playing(index: $0) }
        case (.previous, .playing(let index)), (.previous, .held(let index, _)):
            return .playing(index: previous(before: index) ?? index)
        case (.previous, .ended):
            return lastEnabled.map { .playing(index: $0) }
        case (.jump(let id), _):
            guard let index = playlist.index(ofItem: id), playlist.items[index].enabled else { return nil }
            return .playing(index: index)
        case (.restartItem, .playing(let index)), (.restartItem, .held(let index, _)):
            return .playing(index: index)
        default:
            return nil
        }
    }

    private func playOrEnd(_ index: Int?) -> SequencerState {
        index.map { .playing(index: $0) } ?? .ended
    }

    private func afterItemEnded(_ index: Int) -> SequencerState {
        let item = playlist.items[index]
        if playlist.mode == .stopAfterEach || item.stopAfter {
            return .held(index: index, cued: next(after: index))
        }
        return playOrEnd(next(after: index))
    }

    // MARK: - Navegación

    private var firstEnabled: Int? { playlist.items.firstIndex(where: \.enabled) }
    private var lastEnabled: Int? { playlist.items.lastIndex(where: \.enabled) }

    /// Siguiente habilitado estrictamente después de `index` (con bucle, puede volver a `index`).
    private func next(after index: Int) -> Int? {
        let items = playlist.items
        if let found = items.indices.first(where: { $0 > index && items[$0].enabled }) { return found }
        return playlist.loop ? firstEnabled : nil
    }

    /// Anterior habilitado estrictamente antes de `index` (con bucle, puede volver a `index`).
    private func previous(before index: Int) -> Int? {
        let items = playlist.items
        if let found = items.indices.last(where: { $0 < index && items[$0].enabled }) { return found }
        return playlist.loop ? lastEnabled : nil
    }

    // MARK: - Edición

    private mutating func reconcile(oldItems: [PlaylistItem]) {
        switch state {
        case .idle, .ended:
            return
        case .playing(let oldIndex):
            if let index = playlist.index(ofItem: oldItems[oldIndex].id) {
                state = .playing(index: index)
            } else {
                state = playOrEnd(successor(fromPosition: oldIndex))
            }
        case .held(let oldIndex, _):
            if let index = playlist.index(ofItem: oldItems[oldIndex].id) {
                state = .held(index: index, cued: next(after: index))
            } else {
                state = .ended
            }
        }
    }

    /// Primer habilitado en `position` o después (con bucle, desde el principio).
    private func successor(fromPosition position: Int) -> Int? {
        let items = playlist.items
        if let found = items.indices.first(where: { $0 >= position && items[$0].enabled }) { return found }
        return playlist.loop ? firstEnabled : nil
    }
}
