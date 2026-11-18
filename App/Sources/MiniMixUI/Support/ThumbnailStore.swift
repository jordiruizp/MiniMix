import AVFoundation
import Core
import CoreGraphics
import ImageIO
import Observation

/// Qué pinta la miniatura de una entrada: un color sólido o un fotograma/imagen de archivo.
enum ThumbnailSource: Hashable, Sendable {
    case color(RGBAColor)
    case media(ThumbnailStore.Key)
}

extension InputDescriptor {
    /// Color, imagen, primer fotograma del vídeo (desde su punto de entrada) o cartela del audio.
    /// En una playlist, el primer item de vídeo activo; si no hay, su primer item visual.
    var thumbnailSource: ThumbnailSource? {
        switch content {
        case .color(let color): .color(color)
        case .image(let ref): .media(.init(path: ref.path, kind: .image))
        case .video(let ref): .media(.init(path: ref.path, kind: .video, time: inPoint ?? 0))
        case .audio(_, visual: .card(let ref)): .media(.init(path: ref.path, kind: .image))
        case .audio: nil
        case .playlist(let playlist): playlist.thumbnailSource
        }
    }
}

extension Playlist {
    var thumbnailSource: ThumbnailSource? {
        let active = items.filter(\.enabled)
        let item = active.first { if case .video = $0.source { true } else { false } }
            ?? active.first { if case .audio = $0.source { false } else { true } }
        switch item?.source {
        case .video(let ref): return .media(.init(path: ref.path, kind: .video, time: item?.inPoint ?? 0))
        case .image(let ref): return .media(.init(path: ref.path, kind: .image))
        case .color(let color): return .color(color)
        case .audio, nil: return nil
        }
    }
}

/// Miniaturas de las entradas, generadas una vez fuera del hilo principal y reducidas al tamaño
/// de la tarjeta (2×). Los archivos se leen por ruta: Persistence ya mantiene abierto su acceso
/// security-scoped mientras el proyecto los referencia.
@MainActor @Observable
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    struct Key: Hashable, Sendable {
        enum Kind: Sendable { case video, image }
        let path: String
        let kind: Kind
        var time: Double = 0
    }

    /// Lado mayor en píxeles: tarjeta de 176×99 pt en pantalla Retina.
    nonisolated static let maxPixelSize = 352

    private(set) var images: [Key: CGImage] = [:]
    @ObservationIgnored private var loading: Set<Key> = []
    @ObservationIgnored private var failed: Set<Key> = []

    func image(for key: Key) -> CGImage? { images[key] }

    /// Genera la miniatura si aún no existe (ni falló antes); no hace nada si ya se está generando.
    func load(_ key: Key) async {
        guard images[key] == nil, !loading.contains(key), !failed.contains(key) else { return }
        loading.insert(key)
        let image = await Self.generate(key)
        loading.remove(key)
        if let image { images[key] = image } else { failed.insert(key) }
    }

    @concurrent
    nonisolated static func generate(_ key: Key) async -> CGImage? {
        let url = URL(fileURLWithPath: key.path)
        switch key.kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            let time = CMTime(seconds: key.time, preferredTimescale: 600)
            guard let frame = try? await generator.image(at: time) else { return nil }
            return frame.image
        }
    }
}
