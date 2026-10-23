import Core
import Metal

/// Debe coincidir con `CompositorUniforms` en `ShaderSource`.
struct CompositorUniforms {
    var rectA: SIMD4<Float>
    var rectB: SIMD4<Float>
    var background: SIMD4<Float>
    var mixValue: Float
    var kind: UInt32
    var hasA: UInt32
    var hasB: UInt32
    var wipeSoftness: Float
}

/// Compositor Metal del lienzo de Programa (T21).
///
/// Un solo pase de pantalla completa: encaja `a` y `b` (fit/fill/stretch, alfa
/// premultiplicado), los mezcla según `kind` (cut, fade con `mix` ya curvado,
/// wipe horizontal) y compone el resultado sobre `backgroundColor`. Una entrada
/// `nil` es transparente. No espera a la GPU ni bloquea: los pipelines se
/// compilan en `init`/`prepare(pixelFormat:)`, nunca en `encode`. Si se codifica
/// en un formato no preparado, el destino se limpia con `backgroundColor` y se
/// cuenta en `missingPipelineFrames` (y se registra en el log una vez).
public final class Compositor: Compositing, @unchecked Sendable {
    public let context: MetalContext
    public var device: MTLDevice { context.device }
    /// Estadísticas de los fotogramas codificados con `encode` (si `collectsStats`).
    public let statsCollector: RenderStatsCollector
    public let collectsStats: Bool

    private struct Settings {
        var background: RGBAColor = .black
        var wipeSoftness: Float = 0.005
    }

    private let settings = UnfairLocked(Settings())
    private let pipelines: PipelineCache
    /// Textura 1×1 transparente que se enlaza cuando una entrada es `nil`.
    private let emptyTexture: MTLTexture

    /// - Parameters:
    ///   - pixelFormats: formatos de destino a precompilar.
    ///   - frameRate: para detectar fotogramas perdidos en `stats`.
    public init(context: MetalContext, pixelFormats: [MTLPixelFormat] = [.bgra8Unorm],
                frameRate: FrameRate = .fps60, collectsStats: Bool = true) throws {
        self.context = context
        self.pipelines = PipelineCache(name: "Compositor") { format in
            try context.makeFullscreenPipeline(
                fragment: "minimix_compositor_fragment", pixelFormat: format, label: "MiniMix.Compositor")
        }
        self.statsCollector = RenderStatsCollector(frameRate: frameRate)
        self.collectsStats = collectsStats
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1,
                                                            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let empty = context.device.makeTexture(descriptor: desc) else { throw RenderError.textureAllocationFailed }
        let zero: [UInt8] = [0, 0, 0, 0]
        empty.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: zero, bytesPerRow: 4)
        self.emptyTexture = empty
        for format in pixelFormats { try prepare(pixelFormat: format) }
    }

    /// Compila y cachea el pipeline para destinos `pixelFormat`. Llamar en la
    /// configuración (puede tardar); `encode` nunca compila.
    public func prepare(pixelFormat: MTLPixelFormat) throws {
        try pipelines.prepare(pixelFormat)
    }

    /// Fotogramas codificados en un formato no preparado (se limpiaron con el fondo).
    public var missingPipelineFrames: Int { pipelines.missCount }

    /// Color sobre el que se compone (lo que se ve donde no hay fuente). Por defecto negro opaco;
    /// `.clear` deja el lienzo transparente.
    public var backgroundColor: RGBAColor {
        get { settings.withLock { $0.background } }
        set { settings.withLock { $0.background = newValue } }
    }

    /// Semiancho del borde suave del wipe, en fracción del ancho del lienzo.
    public var wipeSoftness: Float {
        get { settings.withLock { $0.wipeSoftness } }
        set { settings.withLock { $0.wipeSoftness = max(0, newValue) } }
    }

    public var stats: RenderStats { statsCollector.stats }

    public func encode(_ frame: CompositorFrame, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let pipeline = pipelines.pipeline(for: target.pixelFormat) else {
            commandBuffer.encodeClear(target, color: backgroundColor.premultipliedSIMD)
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let canvas = PixelSize(width: target.width, height: target.height)
        let current = settings.withLock { $0 }
        var uniforms = CompositorUniforms(
            rectA: Self.rect(frame.a, frame.fitA, canvas),
            rectB: Self.rect(frame.b, frame.fitB, canvas),
            background: current.background.premultipliedSIMD,
            mixValue: min(max(frame.mix, 0), 1),
            kind: Self.kindCode(frame.kind),
            hasA: frame.a == nil ? 0 : 1,
            hasB: frame.b == nil ? 0 : 1,
            wipeSoftness: current.wipeSoftness)

        encoder.label = "MiniMix.Compositor"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositorUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame.a ?? emptyTexture, index: 0)
        encoder.setFragmentTexture(frame.b ?? emptyTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        if collectsStats {
            statsCollector.frameSubmitted(at: RenderStatsCollector.hostSeconds())
            let collector = statsCollector
            commandBuffer.addCompletedHandler { buffer in
                guard buffer.status == .completed else { return }
                collector.gpuFrameCompleted(gpuTime: buffer.gpuEndTime - buffer.gpuStartTime)
            }
        }
    }

    private static func rect(_ texture: MTLTexture?, _ fit: FitMode, _ canvas: PixelSize) -> SIMD4<Float> {
        guard let texture else { return SIMD4(0, 0, 1, 1) }
        return fit.normalizedRect(source: PixelSize(width: texture.width, height: texture.height),
                                  destination: canvas)
    }

    private static func kindCode(_ kind: TransitionKind) -> UInt32 {
        switch kind {
        case .cut: 0
        case .fade: 1
        case .wipe: 2
        }
    }
}

public enum RenderError: Error, Equatable, Sendable {
    case textureAllocationFailed
    case commandBufferFailed
}
