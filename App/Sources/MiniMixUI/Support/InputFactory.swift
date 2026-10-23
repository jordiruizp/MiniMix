import Core
import Foundation

/// Crea entradas y items de playlist a partir de archivos (arrastrar y soltar, abrir).
/// Solo guarda la ruta: el bookmark lo crea Persistence en la integración (T80/T82).
public enum InputFactory {
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mxf", "mpg", "mpeg"]
    public static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "gif", "webp"]

    public static func kind(for url: URL) -> InputKind? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }

    /// Entrada para un archivo, o nil si la extensión no es de vídeo, audio ni imagen.
    public static func descriptor(for url: URL) -> InputDescriptor? {
        let ref = MediaReference(path: url.path)
        let name = url.deletingPathExtension().lastPathComponent
        switch kind(for: url) {
        case .video: return InputDescriptor(name: name, content: .video(ref))
        case .audio: return InputDescriptor(name: name, content: .audio(ref, visual: .black))
        case .image: return InputDescriptor(name: name, content: .image(ref))
        default: return nil
        }
    }

    public static func playlistItem(for url: URL) -> PlaylistItem? {
        let ref = MediaReference(path: url.path)
        switch kind(for: url) {
        case .video: return PlaylistItem(source: .video(ref))
        case .audio: return PlaylistItem(source: .audio(ref))
        case .image: return PlaylistItem(source: .image(ref), duration: PlaylistItem.defaultStillDuration)
        default: return nil
        }
    }

    public static func colorInput(number: Int, color: RGBAColor = RGBAColor(red: 0.1, green: 0.1, blue: 0.1)) -> InputDescriptor {
        InputDescriptor(name: "Color \(number)", content: .color(color))
    }

    public static func playlistInput(number: Int) -> InputDescriptor {
        InputDescriptor(name: "Playlist \(number)", content: .playlist(Playlist()))
    }
}

extension ItemSource {
    var mediaReference: MediaReference? {
        switch self {
        case .video(let ref), .audio(let ref), .image(let ref): ref
        case .color: nil
        }
    }

    var isStill: Bool {
        switch self {
        case .image, .color: true
        case .video, .audio: false
        }
    }

    var displayName: String {
        switch self {
        case .color(let color): "Color \(color.hexString)"
        case .video(let ref), .audio(let ref), .image(let ref): URL(fileURLWithPath: ref.path).lastPathComponent
        }
    }

    var symbolName: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .color: "paintpalette"
        }
    }
}

extension InputKind {
    var symbolName: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .color: "paintpalette"
        case .playlist: "list.bullet.rectangle"
        }
    }

    var localizedName: String {
        switch self {
        case .video: "Vídeo"
        case .audio: "Audio"
        case .image: "Imagen"
        case .color: "Color"
        case .playlist: "Playlist"
        }
    }

    /// Tiene canal en el mixer.
    var hasAudio: Bool { self == .video || self == .audio || self == .playlist }
}

extension InputContent {
    var mediaReference: MediaReference? {
        switch self {
        case .video(let ref), .audio(let ref, _), .image(let ref): ref
        case .color, .playlist: nil
        }
    }

    var playlist: Playlist? {
        if case .playlist(let playlist) = self { return playlist }
        return nil
    }
}
