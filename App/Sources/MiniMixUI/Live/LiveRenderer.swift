import Core
import Metal
import os
import Render

/// Bucle de render de la integración (T80): en cada tick del `MasterClock` compone Programa
/// (con la transición en curso) y Preview, y los publica en sus `MonitorFeed`. El feed de
/// Programa también alimenta la salida externa (Output).
///
/// Reglas (CLAUDE.md / Media): no bloquea ni espera a la GPU; como máximo
/// `maxFramesInFlight` command buffers en vuelo (si se alcanza, el fotograma se cuenta como
/// perdido); las texturas de fuente no se guardan entre fotogramas.
public final class LiveRenderer: @unchecked Sendable {
    // @unchecked: todo el estado mutable está tras `state` (cerrojo corto) o es atómico;
    // MetalContext, Compositor, TexturePool y MonitorFeed son thread-safe.
    public static let maxFramesInFlight = 3

    public let context: MetalContext
    public let canvas: PixelSize
    public let previewFeed = MonitorFeed()
    public let programFeed = MonitorFeed()
    let programCompositor: Compositor
    let previewCompositor: Compositor
    let pool: TexturePool

    private let sources: @Sendable (InputID) -> FrameSource?
    private let state = OSAllocatedUnfairLock(initialState: BusState.empty)
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)
    private let frames = OSAllocatedUnfairLock(initialState: 0)

    /// - Parameter sources: resuelve una entrada a su fuente (normalmente `InputManaging.frameSource(for:)`).
    public init(context: MetalContext, canvas: PixelSize, frameRate: FrameRate,
                sources: @escaping @Sendable (InputID) -> FrameSource?) throws {
        self.context = context
        self.canvas = canvas
        self.sources = sources
        programCompositor = try Compositor(context: context, frameRate: frameRate, statsMode: .external)
        previewCompositor = try Compositor(context: context, frameRate: frameRate, statsMode: .disabled)
        pool = TexturePool(device: context.device)
    }

    /// Lo llama la interfaz cada vez que cambian buses, transición o encajes.
    public func update(_ bus: BusState) { state.withLock { $0 = bus } }

    public var bus: BusState { state.withLock { $0 } }
    public var stats: RenderStats { programCompositor.stats }
    /// Fotogramas codificados desde el arranque (diagnóstico y tests).
    public var renderedFrames: Int { frames.withLock { $0 } }

    /// Consume los ticks del reloj hasta que el stream termine o la tarea se cancele.
    public func run(ticks: AsyncStream<HostTime>) async {
        for await time in ticks {
            if Task.isCancelled { break }
            render(at: time)
        }
    }

    /// Compone un fotograma. Devuelve el command buffer enviado (nil si se descartó).
    @discardableResult
    public func render(at time: HostTime) -> MTLCommandBuffer? {
        let admitted = inFlight.withLock { count -> Bool in
            guard count < Self.maxFramesInFlight else { return false }
            count += 1
            return true
        }
        // Si se alcanza el límite, el tick se descarta. No se llama a `reportDropped()`: en modo
        // `.external` el colector ya cuenta el hueco entre `frameSubmitted` como fotograma perdido.
        guard admitted else { return nil }
        let programTarget = pool.dequeue(width: canvas.width, height: canvas.height)
        let previewTarget = pool.dequeue(width: canvas.width, height: canvas.height)
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let programTarget, let previewTarget else {
            [programTarget, previewTarget].compactMap { $0 }.forEach { pool.recycle($0) }
            inFlight.withLock { $0 -= 1 }
            return nil
        }
        commandBuffer.label = "MiniMix.Frame"
        let bus = self.bus
        programCompositor.encode(programFrame(bus, at: time), into: programTarget, commandBuffer: commandBuffer)
        previewCompositor.encode(previewFrame(bus, at: time), into: previewTarget, commandBuffer: commandBuffer)

        // El tiempo de GPU lo registra el propio Compositor (.external); aquí solo se libera el hueco.
        let inFlight = self.inFlight
        commandBuffer.addCompletedHandler { _ in inFlight.withLock { $0 -= 1 } }
        programCompositor.frameSubmitted(at: time.seconds)
        commandBuffer.commit()
        // Los monitores y Output codifican en la misma `commandQueue` y los recursos usan hazard
        // tracking por defecto: leen después de este CB y una textura reciclada no se reescribe
        // antes. Si se usara otra cola o `.hazardTrackingModeUntracked`, esto dejaría de valer.
        programFeed.display(programTarget, returningTo: pool)
        previewFeed.display(previewTarget, returningTo: pool)
        frames.withLock { $0 += 1 }
        return commandBuffer
    }

    // MARK: Fotogramas

    func programFrame(_ bus: BusState, at time: HostTime) -> CompositorFrame {
        if let transition = bus.transition {
            let mix = Float(TransitionCurve.videoMix(transition.progress))
            return CompositorFrame(
                a: texture(transition.from, at: time), b: texture(transition.to, at: time),
                mix: mix, kind: transition.kind == .cut ? .fade : transition.kind,
                fitA: fit(transition.from, in: bus), fitB: fit(transition.to, in: bus))
        }
        return CompositorFrame(a: texture(bus.program, at: time), b: nil, mix: 0, kind: .cut,
                               fitA: fit(bus.program, in: bus))
    }

    func previewFrame(_ bus: BusState, at time: HostTime) -> CompositorFrame {
        CompositorFrame(a: texture(bus.preview, at: time), b: nil, mix: 0, kind: .cut,
                        fitA: fit(bus.preview, in: bus))
    }

    private func texture(_ id: InputID?, at time: HostTime) -> MTLTexture? {
        id.flatMap(sources)?.texture(for: time)
    }

    private func fit(_ id: InputID?, in bus: BusState) -> FitMode {
        id.flatMap { bus.fits[$0] } ?? .fit
    }
}
