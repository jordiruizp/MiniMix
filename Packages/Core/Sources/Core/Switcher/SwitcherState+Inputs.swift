// Core/Switcher/SwitcherState+Inputs.swift — baja de entradas en el switcher (T11).

import Foundation

extension SwitcherState {
    /// La entrada `id` se ha eliminado del proyecto: la quita de los buses.
    ///
    /// - Si hay una transición en curso que la usa (saliente o entrante), se cancela sin
    ///   intercambio: `[transitionCancelled, busesChanged]`. Si la T-bar la había movido,
    ///   queda pendiente de rearme (`tbarNeedsRearm`).
    /// - Si no hay transición y está en Preview y/o Programa: `[busesChanged]` con ese bus a nil.
    /// - Si una transición en curso no la usa, o no está en ningún bus: sin efectos.
    public mutating func removeInput(_ id: InputID, at time: HostTime) -> [Effect] {
        guard preview == id || program == id else { return [] }
        var effects: [Effect] = []
        if let current = active {
            if current.usedTBar { tbarNeedsRearm = true }
            active = nil
            effects.append(.transitionCancelled)
        }
        if preview == id { preview = nil }
        if program == id { program = nil }
        effects.append(.busesChanged(preview: preview, program: program))
        return effects
    }
}
