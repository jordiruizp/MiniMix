import Core
import Metal

/// Debe coincidir con `MonitorUniforms` en `ShaderSource`.
struct MonitorUniforms {
    var contentRect: SIMD4<Float>
    var borderColor: SIMD4<Float>
    var viewport: SIMD2<Float>
    var borderWidth: Float
    var hasTexture: UInt32
}

/// Borde de un monitor (verde PVW, rojo PGM… lo decide la UI).
public struct MonitorBorder: Hashable, Sendable {
    public var color: RGBAColor
    /// Ancho en píxeles del destino.
    public var width: Float
    public init(color: RGBAColor, width: Float) {
        self.color = color
        self.width = width
    }
}

/// Dibuja la textura del lienzo en un destino (drawable de un monitor o textura
/// fuera de pantalla) encajada con letterbox sobre negro y con un borde opcional.
/// No es `@MainActor`: lo usa `MonitorView` y también los tests sin ventana.
public final class MonitorRenderer: @unchecked Sendable {
    public let context: MetalContext
    private let pipelines = UnfairLocked<[UInt: MTLRenderPipelineState]>([:])

    /// Precompila el pipeline para `pixelFormat` (el del drawable).
    public init(context: MetalContext, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.context = context
        _ = try pipeline(for: pixelFormat)
    }

    /// Rectángulo (x, y, ancho, alto) en píxeles donde se dibuja una textura
    /// `source` en un destino `destination` con un borde de `borderWidth` píxeles.
    public static func contentRect(source: PixelSize, destination: PixelSize, borderWidth: Float) -> SIMD4<Float> {
        let inner = SIMD2<Float>(Float(destination.width), Float(destination.height)) - 2 * borderWidth
        guard inner.x > 0, inner.y > 0 else { return .zero }
        let innerSize = PixelSize(width: max(1, Int(inner.x.rounded())), height: max(1, Int(inner.y.rounded())))
        let norm = FitMode.fit.normalizedRect(source: source, destination: innerSize)
        return SIMD4(borderWidth + norm.x * inner.x, borderWidth + norm.y * inner.y,
                     norm.z * inner.x, norm.w * inner.y)
    }

    /// Codifica el monitor en `target` (p. ej. textura de un drawable).
    public func encode(_ texture: MTLTexture?, into target: MTLTexture, border: MonitorBorder?,
                       commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        encode(texture, pass: pass, border: border, commandBuffer: commandBuffer)
    }

    /// Variante con un pase ya preparado (p. ej. `MTKView.currentRenderPassDescriptor`);
    /// el tamaño y el formato salen de su textura de color 0.
    public func encode(_ texture: MTLTexture?, pass: MTLRenderPassDescriptor, border: MonitorBorder?,
                       commandBuffer: MTLCommandBuffer) {
        guard let target = pass.colorAttachments[0].texture,
              let pipeline = try? pipeline(for: target.pixelFormat),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let targetSize = PixelSize(width: target.width, height: target.height)
        let width = max(0, border?.width ?? 0)
        let source = texture.map { PixelSize(width: $0.width, height: $0.height) } ?? targetSize
        var uniforms = MonitorUniforms(
            contentRect: Self.contentRect(source: source, destination: targetSize, borderWidth: width),
            borderColor: (border?.color ?? .clear).premultipliedSIMD,
            viewport: SIMD2(Float(targetSize.width), Float(targetSize.height)),
            borderWidth: width,
            hasTexture: texture == nil ? 0 : 1)
        encoder.label = "MiniMix.Monitor"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = pipelines.withLock({ $0[format.rawValue] }) { return cached }
        let state = try context.makeFullscreenPipeline(
            fragment: "minimix_monitor_fragment", pixelFormat: format, label: "MiniMix.Monitor")
        pipelines.withLock { $0[format.rawValue] = state }
        return state
    }
}

extension RGBAColor {
    /// Color con alfa premultiplicado, como lo esperan los shaders.
    var premultipliedSIMD: SIMD4<Float> {
        let alpha = Float(min(max(alpha, 0), 1))
        return SIMD4(Float(red) * alpha, Float(green) * alpha, Float(blue) * alpha, alpha)
    }
}
