// Core/Models/Project+Lookup.swift — búsqueda de entradas e items (T10).

import Foundation

extension Project {
    /// Entrada con ese id, si existe.
    public func input(withID id: InputID) -> InputDescriptor? {
        inputs.first { $0.id == id }
    }

    /// Posición de la entrada en `inputs`.
    public func index(ofInput id: InputID) -> Int? {
        inputs.firstIndex { $0.id == id }
    }

    /// `true` si existe una entrada con ese id.
    public func contains(_ id: InputID) -> Bool {
        index(ofInput: id) != nil
    }

    /// Entradas de un tipo, en orden.
    public func inputs(ofKind kind: InputKind) -> [InputDescriptor] {
        inputs.filter { $0.kind == kind }
    }

    /// Primera entrada con ese nombre exacto.
    public func input(named name: String) -> InputDescriptor? {
        inputs.first { $0.name == name }
    }

    /// Entrada en Preview / Programa (nil si no hay o si el id no existe).
    public var previewInput: InputDescriptor? { preview.flatMap(input(withID:)) }
    public var programInput: InputDescriptor? { program.flatMap(input(withID:)) }

    /// Modifica en sitio la entrada con ese id. Devuelve false si no existe.
    @discardableResult
    public mutating func updateInput(_ id: InputID, _ body: (inout InputDescriptor) -> Void) -> Bool {
        guard let index = index(ofInput: id) else { return false }
        body(&inputs[index])
        return true
    }

    /// Quita una entrada y limpia los buses que la referencian. Devuelve la entrada quitada.
    @discardableResult
    public mutating func removeInput(_ id: InputID) -> InputDescriptor? {
        guard let index = index(ofInput: id) else { return nil }
        if preview == id { preview = nil }
        if program == id { program = nil }
        return inputs.remove(at: index)
    }

    /// Playlist de una entrada de tipo playlist.
    public func playlist(for id: InputID) -> Playlist? {
        guard case .playlist(let playlist)? = input(withID: id)?.content else { return nil }
        return playlist
    }

    /// Localiza un item de playlist en cualquier entrada: (entrada, índice del item).
    public func locateItem(_ itemID: ItemID) -> (input: InputID, index: Int)? {
        for descriptor in inputs {
            guard case .playlist(let playlist) = descriptor.content,
                  let index = playlist.index(ofItem: itemID) else { continue }
            return (descriptor.id, index)
        }
        return nil
    }
}

extension Playlist {
    /// Posición del item en `items` (incluye deshabilitados en la numeración).
    public func index(ofItem id: ItemID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// Item con ese id.
    public func item(withID id: ItemID) -> PlaylistItem? {
        items.first { $0.id == id }
    }

    /// Índices de los items habilitados, en orden.
    public var enabledIndices: [Int] {
        items.indices.filter { items[$0].enabled }
    }
}
