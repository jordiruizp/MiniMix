import AVFoundation
import Core
import Foundation
import Render

/// Recursos compartidos que necesita una `PlaylistInput` para crear y mostrar sus items.
public struct PlaylistEnvironment: Sendable {
    /// Crea la fuente (sin preparar) de un item. Por defecto `PlaylistEnvironment.makeItemSource`.
    public typealias ItemFactory = @Sendable (PlaylistItem, Playlist) throws -> FrameSource
    /// Duración efectiva de un item (s) sin cargarlo (para el tiempo restante de la playlist).
    public typealias DurationProbe = @Sendable (PlaylistItem) async -> Double?

    public let context: MetalContext
    public let textureCache: VideoTextureCache
    public let canvasSize: PixelSize
    /// Reloj maestro: marca el ritmo de la playlist (fin de item, precarga, fundidos).
    public let clock: any MasterClockProtocol
    public let imageLoader: ImageInput.Loader
    public let urlResolver: InputManager.URLResolver
    /// Antelación de la precarga del siguiente item (s).
    public var preloadLead: Double
    /// Margen entre dejar de mostrar un item y liberarlo (command buffers en vuelo).
    public var releaseDelay: Double
    var itemFactory: ItemFactory?
    var durationProbe: DurationProbe?

    public init(context: MetalContext, clock: any MasterClockProtocol, canvasSize: PixelSize = .hd1080,
                textureCache: VideoTextureCache? = nil, imageLoader: ImageInput.Loader? = nil,
                urlResolver: @escaping InputManager.URLResolver = { URL(fileURLWithPath: $0.path) },
                preloadLead: Double = 3, releaseDelay: Double = 0.25) {
        self.context = context
        self.clock = clock
        self.canvasSize = canvasSize
        self.textureCache = textureCache ?? VideoTextureCache(context: context)
        let loader = ImageTextureLoader(context: context)
        self.imageLoader = imageLoader ?? { url, size in try await loader.loadTexture(from: url, maxSize: size) }
        self.urlResolver = urlResolver
        self.preloadLead = preloadLead
        self.releaseDelay = releaseDelay
    }

    /// Sustituye la creación de fuentes y el sondeo de duraciones (tests).
    func with(itemFactory: ItemFactory?, durationProbe: DurationProbe? = nil) -> PlaylistEnvironment {
        var copy = self
        copy.itemFactory = itemFactory
        copy.durationProbe = durationProbe
        return copy
    }

    /// Fuente por defecto de cada item: reutiliza las entradas sueltas de Media.
    /// Los items de audio llevan como visual solo la cartela (`.card`); negro y última
    /// imagen los resuelve `PlaylistInput`.
    public func makeItemSource(_ item: PlaylistItem, in playlist: Playlist) throws -> FrameSource {
        switch item.source {
        case .video(let ref):
            return VideoInput(url: try urlResolver(ref), textureCache: textureCache,
                              inPoint: item.inPoint, outPoint: item.outPoint)
        case .audio(let ref):
            var visual: FrameSource?
            if case .card(let card) = playlist.audioItemVisual {
                visual = ImageInput(url: try urlResolver(card), canvasSize: canvasSize, loader: imageLoader)
            }
            return AudioInput(url: try urlResolver(ref), visual: visual, inPoint: item.inPoint, outPoint: item.outPoint)
        case .image(let ref):
            return ImageInput(url: try urlResolver(ref), canvasSize: canvasSize, loader: imageLoader)
        case .color(let color):
            return ColorInput(color: color, context: context, canvasSize: canvasSize)
        }
    }

    /// Duración efectiva sin decodificar: imagen/color → `effectiveDuration`; vídeo/audio →
    /// duración del archivo (AVURLAsset) recortada por In/Out y por `duration` si la hay.
    public func probeDuration(_ item: PlaylistItem) async -> Double? {
        let ref: MediaReference
        switch item.source {
        case .image, .color: return item.effectiveDuration
        case .video(let r), .audio(let r): ref = r
        }
        guard let url = try? urlResolver(ref),
              let file = try? await AVURLAsset(url: url).load(.duration).seconds, file.isFinite else { return item.duration }
        return Self.effectiveMediaDuration(item, fileDuration: file)
    }

    /// `min(duration, Out − In)` con Out/In acotados al archivo.
    static func effectiveMediaDuration(_ item: PlaylistItem, fileDuration: Double) -> Double {
        let upper = min(item.outPoint ?? fileDuration, fileDuration)
        let span = max(0, upper - (item.inPoint ?? 0))
        return min(item.duration ?? span, span)
    }
}
