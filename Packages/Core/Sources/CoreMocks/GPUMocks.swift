// Mocks de los contratos que dependen de Metal / AVFAudio.

#if canImport(Metal) && canImport(AVFAudio)
import AVFAudio
import Core
import Metal

/// Fuente que devuelve una textura de color sólido (creada una sola vez).
public final class MockFrameSource: FrameSource, @unchecked Sendable {
    public let id: InputID
    public let nativeSize: PixelSize
    private let color: RGBAColor
    private let device: MTLDevice?
    private let state = Locked<(PlaybackState, MTLTexture?)>((.idle, nil))
    public let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    public init(id: InputID = InputID(), color: RGBAColor = .black,
                size: PixelSize = PixelSize(width: 64, height: 36),
                device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.id = id
        self.color = color
        self.nativeSize = size
        self.device = device
        (events, continuation) = AsyncStream.makeStream()
    }

    public func prepare() async throws {
        guard let device else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: nativeSize.width, height: nativeSize.height, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return }
        let px: [UInt8] = [color.blue, color.green, color.red, color.alpha].map { UInt8(($0 * 255).rounded()) }
        let row = (0..<nativeSize.width * 4).map { px[$0 % 4] }
        for y in 0..<nativeSize.height {
            row.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, y, nativeSize.width, 1), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: nativeSize.width * 4)
            }
        }
        state.withLock { $0.1 = texture }
    }

    public func texture(for time: HostTime) -> MTLTexture? { state.withLock { $0.1 } }
    public func play() { state.withLock { $0.0 = .playing } }
    public func pause() { state.withLock { $0.0 = .paused } }
    public func seek(to seconds: Double) async {}
    public var playbackState: PlaybackState { state.withLock { $0.0 } }

    /// Simula el fin de la fuente.
    public func finish() {
        state.withLock { $0.0 = .ended }
        continuation.yield(.ended)
    }
}

public final class MockAudioSource: AudioSource, @unchecked Sendable {
    public let id: InputID
    public let node: AVAudioNode?
    public init(id: InputID = InputID(), node: AVAudioNode? = nil) {
        self.id = id
        self.node = node
    }
}

/// Gestor de entradas en memoria: crea `MockFrameSource` de colores.
public final class MockInputManager: InputManaging {
    private let sources = Locked([InputID: MockFrameSource]())
    public let visible = Locked(Set<InputID>())
    public init() {}

    public func add(_ descriptor: InputDescriptor) async throws {
        let color: RGBAColor = if case .color(let c) = descriptor.content { c } else { .black }
        let source = MockFrameSource(id: descriptor.id, color: color)
        try await source.prepare()
        sources.withLock { $0[descriptor.id] = source }
    }

    public func remove(_ id: InputID) async { sources.withLock { $0[id] = nil } }
    public let updates = Locked([InputDescriptor]())
    public func update(_ descriptor: InputDescriptor) async throws {
        updates.withLock { $0.append(descriptor) }
        try await add(descriptor)
    }
    public func frameSource(for id: InputID) -> FrameSource? { sources.withLock { $0[id] } }
    public func audioSource(for id: InputID) -> AudioSource? { nil }
    public func setVisible(_ ids: Set<InputID>) { visible.withLock { $0 = ids } }
}

/// Compositor que solo registra los fotogramas recibidos (no dibuja).
public final class MockCompositor: Compositing, @unchecked Sendable {
    public let device: MTLDevice
    public let mixes = Locked([Float]())
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        self.device = device
    }
    public func encode(_ frame: CompositorFrame, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        mixes.withLock { $0.append(frame.mix) }
    }
}
#endif
