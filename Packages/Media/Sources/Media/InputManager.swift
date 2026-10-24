import Core
import Foundation
import Render

/// Alta/baja de entradas y control de decodificación (T32).
///
/// - Crea la fuente adecuada para cada `InputDescriptor` y la prepara.
/// - `.playlist` se delega en `playlistFactory` (PlaylistInput, agente D); sin
///   fábrica, `add` lanza `MediaError.unsupported`.
/// - `setVisible`: las entradas no visibles se pausan (rate 0, sin decodificar)
///   sin perder su estado lógico; de las visibles, como mucho
///   `maxActiveVideoDecoders` (4) decodifican vídeo, por orden de alta.
///   Hasta la primera llamada a `setVisible` todas cuentan como visibles.
/// - Las entradas de solo audio no se pausan al ocultarlas (su audio no depende
///   de que se vean).
public final class InputManager: InputManaging {
    public typealias PlaylistFactory = @Sendable (InputDescriptor) async throws -> FrameSource
    public typealias URLResolver = @Sendable (MediaReference) throws -> URL

    private struct Entry {
        let id: InputID
        let source: FrameSource
    }

    private struct State {
        /// En orden de alta (decide qué decodificadores ganan si hay más de 4 visibles).
        var entries: [Entry] = []
        var visible: Set<InputID>?
        var activeDecoders: Set<InputID> = []
    }

    public let context: MetalContext
    public let canvasSize: PixelSize
    public let maxActiveVideoDecoders: Int
    public let textureCache: VideoTextureCache
    private let imageLoader: ImageInput.Loader
    private let urlResolver: URLResolver
    private let playlistFactory: PlaylistFactory?
    private let state = LockedState(State())

    /// - Parameters:
    ///   - imageLoader: cargador de imágenes (por defecto `ImageTextureLoader` de Render).
    ///   - urlResolver: resuelve `MediaReference` → URL (Persistence resuelve los
    ///     bookmarks; por defecto se usa `path`).
    ///   - playlistFactory: crea la fuente de una entrada `.playlist`.
    public init(context: MetalContext, canvasSize: PixelSize = .hd1080, maxActiveVideoDecoders: Int = 4,
                imageLoader: ImageInput.Loader? = nil,
                urlResolver: @escaping URLResolver = { URL(fileURLWithPath: $0.path) },
                playlistFactory: PlaylistFactory? = nil) {
        self.context = context
        self.canvasSize = canvasSize
        self.maxActiveVideoDecoders = maxActiveVideoDecoders
        textureCache = VideoTextureCache(context: context)
        let loader = ImageTextureLoader(context: context)
        self.imageLoader = imageLoader ?? { url, size in try await loader.loadTexture(from: url, maxSize: size) }
        self.urlResolver = urlResolver
        self.playlistFactory = playlistFactory
    }

    // MARK: InputManaging

    public func add(_ descriptor: InputDescriptor) async throws {
        if state.withLock({ s in s.entries.contains { $0.id == descriptor.id } }) {
            throw MediaError.duplicate(descriptor.id.description)
        }
        let source = try await makeSource(for: descriptor)
        try await source.prepare()
        let inserted = state.withLock { s -> Bool in
            guard !s.entries.contains(where: { $0.id == descriptor.id }) else { return false }
            s.entries.append(Entry(id: descriptor.id, source: source))
            return true
        }
        guard inserted else { throw MediaError.duplicate(descriptor.id.description) }
        applyVisibility()
    }

    public func remove(_ id: InputID) async {
        let removed = state.withLock { s -> FrameSource? in
            guard let index = s.entries.firstIndex(where: { $0.id == id }) else { return nil }
            s.activeDecoders.remove(id)
            return s.entries.remove(at: index).source
        }
        removed?.pause()
        (removed as? DecodingControllable)?.setDecodingEnabled(false)
        applyVisibility()
    }

    /// contracts-v2. Provisional: se completa en el siguiente commit.
    public func update(_ descriptor: InputDescriptor) async throws {
        throw MediaError.unsupported("update")
    }

    public func frameSource(for id: InputID) -> FrameSource? {
        state.withLock { s in s.entries.first { $0.id == id }?.source }
    }

    public func audioSource(for id: InputID) -> AudioSource? {
        guard let audio = frameSource(for: id) as? AudioSource, audio.node != nil else { return nil }
        return audio
    }

    public func setVisible(_ ids: Set<InputID>) {
        state.withLock { $0.visible = ids }
        applyVisibility()
    }

    // MARK: Consulta

    public var inputIDs: [InputID] { state.withLock { $0.entries.map(\.id) } }

    /// Entradas cuyo decodificador de vídeo está habilitado ahora mismo.
    public var activeDecoderIDs: Set<InputID> { state.withLock { $0.activeDecoders } }

    // MARK: Internos

    private func makeSource(for descriptor: InputDescriptor) async throws -> FrameSource {
        let id = descriptor.id
        switch descriptor.content {
        case .video(let ref):
            return VideoInput(id: id, url: try urlResolver(ref), textureCache: textureCache,
                              loop: descriptor.loop, inPoint: descriptor.inPoint, outPoint: descriptor.outPoint)
        case let .audio(ref, visual):
            let visualSource: FrameSource = switch visual {
            case .black, .lastImage: ColorInput(color: .black, context: context, canvasSize: canvasSize)
            case .card(let card): ImageInput(url: try urlResolver(card), canvasSize: canvasSize, loader: imageLoader)
            }
            return AudioInput(id: id, url: try urlResolver(ref), visual: visualSource,
                              loop: descriptor.loop, inPoint: descriptor.inPoint, outPoint: descriptor.outPoint)
        case .image(let ref):
            return ImageInput(id: id, url: try urlResolver(ref), canvasSize: canvasSize, loader: imageLoader)
        case .color(let color):
            return ColorInput(id: id, color: color, context: context, canvasSize: canvasSize)
        case .playlist:
            guard let playlistFactory else { throw MediaError.unsupported("playlist sin fábrica (PlaylistInput)") }
            return try await playlistFactory(descriptor)
        }
    }

    /// Recalcula qué fuentes decodifican: visibles, y de vídeo como mucho `maxActiveVideoDecoders`.
    private func applyVisibility() {
        let decisions = state.withLock { s -> [(DecodingControllable, Bool)] in
            var decoders = 0
            var active = Set<InputID>()
            var result: [(DecodingControllable, Bool)] = []
            for entry in s.entries {
                guard let control = entry.source as? DecodingControllable else { continue }
                var enabled = s.visible?.contains(entry.id) ?? true
                if enabled, control.usesVideoDecoder {
                    enabled = decoders < maxActiveVideoDecoders
                    if enabled {
                        decoders += 1
                        active.insert(entry.id)
                    }
                }
                result.append((control, enabled))
            }
            s.activeDecoders = active
            return result
        }
        for (control, enabled) in decisions { control.setDecodingEnabled(enabled) }
    }
}
