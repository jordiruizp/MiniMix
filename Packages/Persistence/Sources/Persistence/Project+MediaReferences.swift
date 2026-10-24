// Persistence/Project+MediaReferences.swift — recorrido de todas las `MediaReference` de un proyecto.

import Core
import Foundation

extension Project {
    /// Todas las referencias a archivos del proyecto, en orden de aparición (con repeticiones):
    /// entradas de vídeo/audio/imagen, cartelas de audio y los items (y la cartela) de cada playlist.
    public var mediaReferences: [MediaReference] {
        var found: [MediaReference] = []
        _ = mapMediaReferences { reference in
            found.append(reference)
            return reference
        }
        return found
    }

    /// Copia del proyecto con cada `MediaReference` sustituida por `transform(referencia)`.
    public func mapMediaReferences(_ transform: (MediaReference) throws -> MediaReference) rethrows -> Project {
        var copy = self
        for index in copy.inputs.indices {
            copy.inputs[index].content = try copy.inputs[index].content.mapMediaReferences(transform)
        }
        return copy
    }
}

extension InputContent {
    func mapMediaReferences(_ transform: (MediaReference) throws -> MediaReference) rethrows -> InputContent {
        switch self {
        case .video(let reference):
            .video(try transform(reference))
        case let .audio(reference, visual):
            .audio(try transform(reference), visual: try visual.mapMediaReferences(transform))
        case .image(let reference):
            .image(try transform(reference))
        case .color:
            self
        case .playlist(let playlist):
            .playlist(try playlist.mapMediaReferences(transform))
        }
    }
}

extension AudioVisual {
    func mapMediaReferences(_ transform: (MediaReference) throws -> MediaReference) rethrows -> AudioVisual {
        guard case .card(let reference) = self else { return self }
        return .card(try transform(reference))
    }
}

extension Playlist {
    func mapMediaReferences(_ transform: (MediaReference) throws -> MediaReference) rethrows -> Playlist {
        var copy = self
        for index in copy.items.indices {
            copy.items[index].source = try copy.items[index].source.mapMediaReferences(transform)
        }
        copy.audioItemVisual = try copy.audioItemVisual.mapMediaReferences(transform)
        return copy
    }
}

extension ItemSource {
    func mapMediaReferences(_ transform: (MediaReference) throws -> MediaReference) rethrows -> ItemSource {
        switch self {
        case .video(let reference): .video(try transform(reference))
        case .audio(let reference): .audio(try transform(reference))
        case .image(let reference): .image(try transform(reference))
        case .color: self
        }
    }
}
