import Core
import Metal

public extension MetalContext {
    /// Codifica un relleno de color sólido en `target` (pase de render con
    /// `loadAction = .clear`, sin dibujar nada). El color se escribe premultiplicado.
    func encodeSolidColor(_ color: RGBAColor, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let premultiplied = color.premultipliedSIMD
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(premultiplied.x), green: Double(premultiplied.y),
            blue: Double(premultiplied.z), alpha: Double(premultiplied.w))
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "MiniMix.SolidColor"
        encoder.endEncoding()
    }

    /// Textura de color sólido para una entrada de color (`ColorInput`).
    ///
    /// Para no gastar memoria, la textura es pequeña pero con el **mismo aspecto**
    /// que `aspect` (p. ej. 1920×1080 → 16×9), de modo que cualquier `FitMode`
    /// cubre el lienzo entero. Se rellena en la GPU con un command buffer propio
    /// que se envía sin esperar; los command buffers posteriores de la misma
    /// cola ven ya el color.
    func makeSolidColorTexture(_ color: RGBAColor, aspect: PixelSize = .hd1080,
                               pixelFormat: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let size = Self.reducedAspect(aspect)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: size.width, height: size.height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        texture.label = "MiniMix.SolidColor"
        commandBuffer.label = "MiniMix.SolidColor"
        encodeSolidColor(color, into: texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        return texture
    }

    /// Tamaño mínimo con el mismo aspecto (divide por el MCD).
    internal static func reducedAspect(_ size: PixelSize) -> PixelSize {
        let width = max(1, size.width)
        let height = max(1, size.height)
        var (x, y) = (width, height)
        while y != 0 { (x, y) = (y, x % y) }
        return PixelSize(width: width / x, height: height / x)
    }
}
