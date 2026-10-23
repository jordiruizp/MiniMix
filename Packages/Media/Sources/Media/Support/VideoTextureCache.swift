import CoreVideo
import Metal
import Render
import Synchronization

/// CVPixelBuffer (IOSurface) → `MTLTexture` sin copias, sobre la
/// `CVMetalTextureCache` compartida de `MetalContext`.
///
/// Añade el vaciado periódico de la caché (Render no lo hace): cada
/// `flushInterval` texturas creadas se llama a `CVMetalTextureCacheFlush`, que
/// libera las entradas que ya nadie retiene. Es barato y no bloquea.
public final class VideoTextureCache: Sendable {
    public let context: MetalContext
    private let created = Atomic<Int>(0)
    private let flushInterval: Int

    public init(context: MetalContext, flushInterval: Int = 120) {
        self.context = context
        self.flushInterval = max(1, flushInterval)
    }

    public var device: MTLDevice { context.device }

    /// Envuelve un CVPixelBuffer BGRA como textura Metal, sin copiar.
    /// Hay que retener el `CVMetalTexture` devuelto mientras la GPU use la textura.
    func makeTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var texture: CVMetalTexture?
        // CVMetalTextureCache es segura entre hilos (la comparte todo el render).
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, context.textureCache, pixelBuffer, nil, pixelFormat, width, height, 0, &texture)
        let count = created.wrappingAdd(1, ordering: .relaxed).newValue
        if count % flushInterval == 0 { flush() }
        return status == kCVReturnSuccess ? texture : nil
    }

    /// Libera las texturas de la caché que ya nadie usa.
    public func flush() {
        CVMetalTextureCacheFlush(context.textureCache, 0)
    }
}
