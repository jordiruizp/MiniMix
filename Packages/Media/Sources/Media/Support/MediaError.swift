import Foundation

/// Errores de las entradas de Media.
public enum MediaError: Error, Equatable, Sendable, CustomStringConvertible {
    /// El archivo no existe o no se puede abrir.
    case unreadable(String)
    /// El archivo no tiene pista de vídeo/audio reproducible.
    case noPlayableTrack(String)
    /// No se pudo crear un recurso de Metal/CoreVideo.
    case metal(String)
    /// Tipo de entrada no soportado por esta fábrica (p. ej. `.playlist` sin fábrica).
    case unsupported(String)
    /// Ya existe una entrada con ese ID.
    case duplicate(String)

    public var description: String {
        switch self {
        case .unreadable(let s): "No se puede leer: \(s)"
        case .noPlayableTrack(let s): "Sin pista reproducible: \(s)"
        case .metal(let s): "Error de Metal: \(s)"
        case .unsupported(let s): "No soportado: \(s)"
        case .duplicate(let s): "Entrada duplicada: \(s)"
        }
    }
}
