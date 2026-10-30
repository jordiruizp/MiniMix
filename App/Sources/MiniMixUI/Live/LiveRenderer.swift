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
///
/// - Los feeds son fijos durante toda la vida del renderer: `reconfigure(canvas:frameRate:)` cambia
///   lienzo y compositores sin tocar monitores ni salida, que siguen enlazados a los mismos feeds.
/// - Las `FrameSource` de los buses se resuelven al publicar el `BusState` (no por fotograma, M7):
///   la UI vuelve a publicar con `sourcesChanged` tras altas, sustituciones y bajas.
public final class LiveRenderer: @unchecked Sendable {
    // @unchecked: todo el estado mutable está tras cerrojos cortos o es atómico;
    // MetalContext, Compositor, TexturePool, MonitorFeed y FrameSource son thread-safe.
    public static let maxFramesInFlight = 3

    public let context: MetalContext
    public let previewFeed = MonitorFeed()
    public let programFeed = MonitorFeed()
    let pool: TexturePool

    /// Lienzo y compositores; se sustituyen juntos al reconfigurar.
    struct Pipeline: Sendable {
        var canvas: PixelSize
        var frameRate: FrameRate
        var program: Compositor
        var preview: Compositor
    }

    /// Buses + fuentes ya resueltas para ellos.
    struct Snapshot: Sendable {
        var bus: BusState
        var sources: [InputID: any FrameSource]
    }

    private let resolve: @Sendable (InputID) -> FrameSource?
    private let pipeline: OSAllocatedUnfairLock<Pipeline>
    private let snapshot = OSAllocatedUnfairLock(initialState: Snapshot(bus: .empty, sources: [:]))
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)
    private let frames = OSAllocatedUnfairLock(initialState: 0)
    /// Fotogramas que faltan para la segunda purga del pool tras reconfigurar (las texturas del
    /// tamaño viejo que estaban en vuelo o en los feeds vuelven al pool después de la primera).
    private let purgeCountdown = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// - Parameter sources: resuelve una entrada a su fuente (normalmente `InputManaging.frameSource(for:)`).
    public init(context: MetalContext, canvas: PixelSize, frameRate: FrameRate,
                sources: @escaping @Sendable (InputID) -> FrameSource?) throws {
        self.context = context
        self.resolve = sources
        pipeline = OSAllocatedUnfairLock(initialState: try Self.makePipeline(context, canvas, frameRate))
        pool = TexturePool(device: context.device)
    }

    private static func makePipeline(_ context: MetalContext, _ canvas: PixelSize, _ rate: FrameRate) throws -> Pipeline {
        Pipeline(canvas: canvas, frameRate: rate,
                 program: try Compositor(context: context, frameRate: rate, statsMode: .external),
                 preview: try Compositor(context: context, frameRate: rate, statsMode: .disabled))
    }

    public var canvas: PixelSize { pipeline.withLock { $0.canvas } }
    public var frameRate: FrameRate { pipeline.withLock { $0.frameRate } }

    /// Cambia lienzo y/o frecuencia (proyecto abierto con otro formato). Los fotogramas en vuelo
    /// terminan con el pipeline anterior; las estadísticas de render empiezan de cero.
    public func reconfigure(canvas: PixelSize, frameRate: FrameRate) throws {
        guard canvas != self.canvas || frameRate != self.frameRate else { return }
        let new = try Self.makePipeline(context, canvas, frameRate)
        pipeline.withLock { $0 = new }
        pool.purge()
        // Las del tamaño viejo aún en vuelo o mostradas en los feeds se reciclan más tarde:
        // segunda purga cuando ya han pasado `maxFramesInFlight` fotogramas (+1 por los feeds).
        purgeCountdown.withLock { $0 = Self.maxFramesInFlight + 1 }
    }

    /// Bytes retenidos por el pool de texturas (diagnóstico y tests).
    var pooledBytes: Int { pool.cachedBytes }

    /// Lo llama la interfaz cada vez que cambian buses, transición o encajes. Con `refreshSources`
    /// (o si hay entradas nuevas en los buses) vuelve a resolver las fuentes.
    public func update(_ bus: BusState, refreshSources: Bool = false) {
        let ids = Set([bus.preview, bus.program, bus.transition?.from, bus.transition?.to].compactMap { $0 })
        let previous = snapshot.withLock { $0.sources }
        var sources: [InputID: any FrameSource] = [:]
        for id in ids {
            if !refreshSources, let cached = previous[id] {
                sources[id] = cached
            } else if let source = resolve(id) {
                sources[id] = source
            }
        }
        let next = Snapshot(bus: bus, sources: sources)
        snapshot.withLock { $0 = next }
    }

    public var bus: BusState { snapshot.withLock { $0.bus } }
    /// Fuentes resueltas para los buses actuales (diagnóstico y tests).
    var cachedSourceIDs: Set<InputID> { snapshot.withLock { Set($0.sources.keys) } }
    public var stats: RenderStats { pipeline.withLock { $0.program }.stats }
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
        let pipe = pipeline.withLock { $0 }
        let programTarget = pool.dequeue(width: pipe.canvas.width, height: pipe.canvas.height)
        let previewTarget = pool.dequeue(width: pipe.canvas.width, height: pipe.canvas.height)
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let programTarget, let previewTarget else {
            [programTarget, previewTarget].compactMap { $0 }.forEach { pool.recycle($0) }
            inFlight.withLock { $0 -= 1 }
            return nil
        }
        commandBuffer.label = "MiniMix.Frame"
        let current = snapshot.withLock { $0 }
        pipe.program.encode(programFrame(current, at: time), into: programTarget, commandBuffer: commandBuffer)
        pipe.preview.encode(previewFrame(current, at: time), into: previewTarget, commandBuffer: commandBuffer)

        // El tiempo de GPU lo registra el propio Compositor (.external); aquí solo se libera el hueco.
        let inFlight = self.inFlight
        commandBuffer.addCompletedHandler { _ in inFlight.withLock { $0 -= 1 } }
        pipe.program.frameSubmitted(at: time.seconds)
        commandBuffer.commit()
        // Los monitores y Output codifican en la misma `commandQueue` y los recursos usan hazard
        // tracking por defecto: leen después de este CB y una textura reciclada no se reescribe
        // antes. Si se usara otra cola o `.hazardTrackingModeUntracked`, esto dejaría de valer.
        programFeed.display(programTarget, returningTo: pool)
        previewFeed.display(previewTarget, returningTo: pool)
        frames.withLock { $0 += 1 }
        let purgeNow = purgeCountdown.withLock { countdown -> Bool in
            guard let left = countdown else { return false }
            countdown = left > 1 ? left - 1 : nil
            return left <= 1
        }
        if purgeNow { pool.purge() }
        return commandBuffer
    }

    // MARK: Fotogramas

    func programFrame(_ current: Snapshot, at time: HostTime) -> CompositorFrame {
        let bus = current.bus
        if let transition = bus.transition {
            let mix = Float(TransitionCurve.videoMix(transition.progress))
            return CompositorFrame(
                a: texture(transition.from, current, at: time), b: texture(transition.to, current, at: time),
                mix: mix, kind: transition.kind == .cut ? .fade : transition.kind,
                fitA: fit(transition.from, in: bus), fitB: fit(transition.to, in: bus))
        }
        return CompositorFrame(a: texture(bus.program, current, at: time), b: nil, mix: 0, kind: .cut,
                               fitA: fit(bus.program, in: bus))
    }

    func previewFrame(_ current: Snapshot, at time: HostTime) -> CompositorFrame {
        CompositorFrame(a: texture(current.bus.preview, current, at: time), b: nil, mix: 0, kind: .cut,
                        fitA: fit(current.bus.preview, in: current.bus))
    }

    private func texture(_ id: InputID?, _ current: Snapshot, at time: HostTime) -> MTLTexture? {
        guard let id else { return nil }
        return current.sources[id]?.texture(for: time)
    }

    private func fit(_ id: InputID?, in bus: BusState) -> FitMode {
        id.flatMap { bus.fits[$0] } ?? .fit
    }
}
