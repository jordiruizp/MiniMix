import Core
import CoreMocks
import Foundation
import Metal
import Render
import TestSupport

/// Fábrica de las piezas que el harness ejercita, expresadas solo con los protocolos del contrato.
///
/// PUNTO DE INYECCIÓN (T80/T90): cuando existan Media.MasterClock y las fuentes reales
/// (Media.InputManager / Playlist), añadir una `RealPipelineFactory` que las devuelva (y declarar
/// la dependencia de Media en `Tools/StressHarness/Package.swift`), y registrarla en
/// `PipelineRegistry.factories` con el nombre "real". El runner y el informe no cambian.
public protocol PipelineFactory: Sendable {
    var name: String { get }
    /// Qué implementación se usa para cada pieza (va al informe).
    var components: [String: String] { get }
    var device: MTLDevice? { get }
    func makeClock(frameRate: FrameRate) -> MasterClockProtocol
    /// nil = sin GPU (el harness mide solo la parte CPU).
    func makeCompositor() -> Compositing?
    func makeSwitcher() -> any SwitcherStateMachine
    func makeSequencer(_ playlist: Playlist) -> any PlaylistSequencing
    /// Crea (sin preparar) la fuente de una entrada o de un item de playlist.
    func makeSource(id: InputID, content: InputContent, canvas: PixelSize) -> FrameSource
}

public enum PipelineRegistry {
    /// Nombre → fábrica. T80/T90: `"real": RealPipelineFactory()`.
    public static let factories: [String: @Sendable () -> PipelineFactory] = [
        "core-render": { CoreRenderPipelineFactory() },
        "mock": { MockPipelineFactory() }
    ]

    public static let defaultName = "core-render"

    public static func make(_ name: String) -> PipelineFactory? { factories[name]?() }
}

/// Implementación con CoreMocks + piezas mínimas del harness para que corra ya:
/// reloj de pared (`WallClock`), compositor de blit (`BlitCompositor`, trabajo real de GPU),
/// `MockSwitcher`, `MockSequencer` y `MockFrameSource` de color a tamaño de lienzo.
public struct MockPipelineFactory: PipelineFactory {
    public let name = "mock"
    public let device: MTLDevice?
    public var components: [String: String] {
        ["clock": "WallClock", "compositor": device == nil ? "none" : "BlitCompositor", "switcher": "MockSwitcher",
         "sequencer": "MockSequencer", "sources": "MockFrameSource"]
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) { self.device = device }

    public func makeClock(frameRate: FrameRate) -> MasterClockProtocol { WallClock(frameRate: frameRate) }
    public func makeCompositor() -> Compositing? { device.flatMap { BlitCompositor(device: $0) } }
    public func makeSwitcher() -> any SwitcherStateMachine { MockSwitcher() }
    public func makeSequencer(_ playlist: Playlist) -> any PlaylistSequencing { MockSequencer(playlist: playlist) }

    public func makeSource(id: InputID, content: InputContent, canvas: PixelSize) -> FrameSource {
        let color: RGBAColor = switch content {
        case .color(let c): c
        default: Self.color(for: id)
        }
        return MockFrameSource(id: id, color: color, size: canvas, device: device)
    }

    /// Color estable derivado del ID (para distinguir fuentes en capturas).
    static func color(for id: InputID) -> RGBAColor {
        let h = UInt(bitPattern: id.hashValue)
        return RGBAColor(red: Double(h & 0xFF) / 255, green: Double(h >> 8 & 0xFF) / 255, blue: Double(h >> 16 & 0xFF) / 255)
    }
}

/// Módulos reales ya integrados (Core.SwitcherState, Core.PlaylistSequencer, Render.Compositor)
/// con reloj de pared y fuentes de color de CoreMocks hasta que existan Media (T30/T31/T35).
public struct CoreRenderPipelineFactory: PipelineFactory {
    public let name = "core-render"
    private let mocks: MockPipelineFactory
    private let context: MetalContext?
    public var device: MTLDevice? { context?.device }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        context = MetalContext(device: device)
        mocks = MockPipelineFactory(device: context?.device)
    }

    public var components: [String: String] {
        ["clock": "WallClock", "compositor": context == nil ? "none" : "Render.Compositor",
         "switcher": "Core.SwitcherState", "sequencer": "Core.PlaylistSequencer", "sources": "MockFrameSource"]
    }

    public func makeClock(frameRate: FrameRate) -> MasterClockProtocol { WallClock(frameRate: frameRate) }
    public func makeCompositor() -> Compositing? {
        context.flatMap { try? Compositor(context: $0, pixelFormats: [.bgra8Unorm]) }
    }
    public func makeSwitcher() -> any SwitcherStateMachine { SwitcherState() }
    public func makeSequencer(_ playlist: Playlist) -> any PlaylistSequencing { PlaylistSequencer(playlist: playlist) }
    public func makeSource(id: InputID, content: InputContent, canvas: PixelSize) -> FrameSource {
        mocks.makeSource(id: id, content: content, canvas: canvas)
    }
}

/// Reloj de tiempo real alineado a la rejilla de fotogramas. Si el consumidor o el planificador
/// se retrasan, salta al fotograma actual (el hueco se cuenta como fotograma perdido).
public final class WallClock: MasterClockProtocol {
    public let frameRate: FrameRate
    public let ticks: AsyncStream<HostTime>
    private let continuation: AsyncStream<HostTime>.Continuation
    private let epoch = LockedBox<ContinuousClock.Instant?>(nil)
    private let task = LockedBox<Task<Void, Never>?>(nil)

    public init(frameRate: FrameRate) {
        self.frameRate = frameRate
        (ticks, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public var now: HostTime {
        guard let start = epoch.withLock({ $0 }) else { return .zero }
        return HostTime(seconds: start.duration(to: .now).seconds)
    }

    public func start() {
        let start = ContinuousClock.now
        epoch.withLock { $0 = start }
        let frame = frameRate.frameDuration
        let continuation = continuation
        let newTask = Task.detached(priority: .high) {
            var index = 1
            while !Task.isCancelled {
                let deadline = start.advanced(by: .seconds(Double(index) * frame))
                try? await Task.sleep(until: deadline, tolerance: .microseconds(250), clock: .continuous)
                let current = Int((start.duration(to: .now).seconds / frame).rounded(.down))
                index = max(index, current)
                continuation.yield(HostTime(seconds: Double(index) * frame))
                index += 1
            }
        }
        task.withLock { $0 = newTask }
    }

    public func stop() {
        task.withLock {
            $0?.cancel()
            $0 = nil
        }
        continuation.finish()
    }
}

/// Compositor mínimo con trabajo real de GPU: copia (blit) la textura dominante al destino.
/// Sustituto de `Render.Compositor` (T21) hasta que exista; el informe indica qué se usó.
public final class BlitCompositor: Compositing, @unchecked Sendable {
    public let device: MTLDevice

    public init(device: MTLDevice) { self.device = device }

    public func encode(_ frame: CompositorFrame, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let source = frame.mix >= 0.5 ? (frame.b ?? frame.a) : (frame.a ?? frame.b)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        if let source, source.width == target.width, source.height == target.height,
           source.pixelFormat == target.pixelFormat {
            blit.copy(from: source, to: target)
        } else if let source {
            let size = MTLSize(width: min(source.width, target.width), height: min(source.height, target.height), depth: 1)
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: size,
                      to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        }
        blit.endEncoding()
    }
}
