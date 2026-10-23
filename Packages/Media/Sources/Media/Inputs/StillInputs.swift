import Core
import Foundation
import Metal
import Render

/// Estado común de las fuentes fijas (color, imagen): no decodifican nada, así
/// que play/pause solo reflejan el estado lógico para la interfaz.
private struct StillState {
    var texture: MTLTexture?
    var size: PixelSize
    var playback: PlaybackState = .idle
}

/// Entrada de color sólido. La textura es diminuta pero con el aspecto del
/// lienzo (`MetalContext.makeSolidColorTexture`); `nativeSize` = tamaño del lienzo.
public final class ColorInput: FrameSource {
    public let id: InputID
    public let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation
    private let context: MetalContext
    private let state: LockedState<StillState>
    private let color: LockedState<RGBAColor>

    public init(id: InputID = InputID(), color: RGBAColor, context: MetalContext, canvasSize: PixelSize = .hd1080) {
        self.id = id
        self.context = context
        self.color = LockedState(color)
        state = LockedState(StillState(size: canvasSize))
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    deinit { continuation.finish() }

    public var nativeSize: PixelSize { state.withLock { $0.size } }
    public var playbackState: PlaybackState { state.withLock { $0.playback } }
    public var currentColor: RGBAColor { color.current }

    public func prepare() async throws {
        if state.withLock({ $0.texture != nil }) { return }
        try rebuild()
    }

    /// Cambia el color (crea una textura nueva; no llamar desde el hilo de render).
    public func setColor(_ newColor: RGBAColor) throws {
        color.withLock { $0 = newColor }
        try rebuild()
    }

    public func texture(for time: HostTime) -> MTLTexture? { state.withLock { $0.texture } }
    public func play() { state.withLock { $0.playback = .playing } }
    public func pause() { state.withLock { $0.playback = .paused } }
    public func seek(to seconds: Double) async {}

    private func rebuild() throws {
        let size = state.withLock { $0.size }
        guard let texture = context.makeSolidColorTexture(color.current, aspect: size) else {
            throw MediaError.metal("no se pudo crear la textura de color")
        }
        state.withLock { $0.texture = texture }
    }
}

/// Entrada de imagen fija: se decodifica una vez, reducida al tamaño del lienzo,
/// con un cargador inyectable (por defecto `Render.ImageTextureLoader`).
public final class ImageInput: FrameSource {
    /// `(url, tamaño máximo) → textura`. Es E/S: nunca se llama desde el hilo de render.
    public typealias Loader = @Sendable (URL, PixelSize) async throws -> MTLTexture

    public let id: InputID
    public let url: URL
    public let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation
    private let loader: Loader
    private let maxSize: PixelSize
    private let state: LockedState<StillState>

    public init(id: InputID = InputID(), url: URL, canvasSize: PixelSize = .hd1080, loader: @escaping Loader) {
        self.id = id
        self.url = url
        self.loader = loader
        maxSize = canvasSize
        state = LockedState(StillState(size: PixelSize(width: 0, height: 0)))
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    /// Cargador por defecto: `ImageTextureLoader` de Render.
    public convenience init(id: InputID = InputID(), url: URL, canvasSize: PixelSize = .hd1080, context: MetalContext) {
        let loader = ImageTextureLoader(context: context)
        self.init(id: id, url: url, canvasSize: canvasSize) { url, size in
            try await loader.loadTexture(from: url, maxSize: size)
        }
    }

    deinit { continuation.finish() }

    public var nativeSize: PixelSize { state.withLock { $0.size } }
    public var playbackState: PlaybackState { state.withLock { $0.playback } }

    public func prepare() async throws {
        if state.withLock({ $0.texture != nil }) { return }
        do {
            let texture = try await loader(url, maxSize)
            state.withLock { s in
                s.texture = texture
                s.size = PixelSize(width: texture.width, height: texture.height)
            }
        } catch {
            continuation.yield(.error(String(describing: error)))
            throw error
        }
    }

    public func texture(for time: HostTime) -> MTLTexture? { state.withLock { $0.texture } }
    public func play() { state.withLock { $0.playback = .playing } }
    public func pause() { state.withLock { $0.playback = .paused } }
    public func seek(to seconds: Double) async {}
}
