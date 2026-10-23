import CoreVideo
import Metal

/// Recursos Metal compartidos por todo el render: dispositivo, cola de comandos,
/// caché de texturas de CoreVideo (CVPixelBuffer → MTLTexture sin copia) y la
/// biblioteca de shaders compilada en tiempo de ejecución.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache

    private let library = UnfairLocked<MTLLibrary?>(nil)

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.commandQueue = queue
        self.textureCache = cache
        queue.label = "MiniMix.Render"
    }

    /// Contexto del dispositivo por defecto; `nil` si no hay GPU Metal.
    public static let shared: MetalContext? = MetalContext()

    /// Biblioteca con todos los shaders de Render, compilada una sola vez
    /// (`makeLibrary(source:options:)`: no hay compilador `metal` en el entorno).
    /// Llamar en la configuración, no en el hilo de render.
    public func shaderLibrary() throws -> MTLLibrary {
        if let cached = library.withLock({ $0 }) { return cached }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let compiled = try device.makeLibrary(source: ShaderSource.msl, options: options)
        return library.withLock { stored in
            if let stored { return stored }
            stored = compiled
            return compiled
        }
    }

    /// Pipeline de pantalla completa (triángulo único) con el fragment shader indicado.
    func makeFullscreenPipeline(fragment: String, pixelFormat: MTLPixelFormat,
                                label: String) throws -> MTLRenderPipelineState {
        let lib = try shaderLibrary()
        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = lib.makeFunction(name: "minimix_fullscreen_vertex")
        desc.fragmentFunction = lib.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: desc)
    }
}
