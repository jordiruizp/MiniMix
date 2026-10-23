import CoreVideo
import Metal

/// Envoltorio de `CVMetalTextureCache`: CVPixelBuffer (IOSurface) → `MTLTexture`
/// sin copias.
///
/// **Punto de inyección (Render · MetalContext):** cuando B integre
/// `MetalContext(device, commandQueue, textureCache)`, el orquestador pasará su
/// caché con `VideoTextureCache(device:cache:)`, y todas las entradas compartirán
/// una sola caché. Mientras tanto cada `InputManager` crea la suya con
/// `VideoTextureCache(device:)`.
///
/// `@unchecked Sendable` justificado: `CVMetalTextureCache` no está anotado como
/// `Sendable`; cada uso pasa por un cerrojo corto (crear una textura es O(µs),
/// sin E/S), así que es seguro llamarlo desde varios hilos de render.
public final class VideoTextureCache: @unchecked Sendable {
    public let device: MTLDevice
    private let cache: LockedState<CVMetalTextureCache>

    /// Crea una caché propia para `device`.
    public convenience init(device: MTLDevice) throws {
        var cache: CVMetalTextureCache?
        let attrs = [kCVMetalTextureCacheMaximumTextureAgeKey as String: 0.5] as CFDictionary
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, attrs, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw MediaError.metal("CVMetalTextureCacheCreate: \(status)")
        }
        self.init(device: device, cache: cache)
    }

    /// Usa una caché existente (p. ej. la de `MetalContext`).
    public init(device: MTLDevice, cache: CVMetalTextureCache) {
        self.device = device
        self.cache = LockedState(cache)
    }

    /// Envuelve un CVPixelBuffer BGRA (o de un plano) como textura Metal, sin copiar.
    /// Hay que retener el `CVMetalTexture` devuelto mientras la GPU use la textura.
    func makeTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return cache.withLock { cache in
            var texture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, pixelFormat, width, height, 0, &texture)
            return status == kCVReturnSuccess ? texture : nil
        }
    }

    /// Libera las texturas que ya nadie usa (llamar de vez en cuando, no por fotograma).
    public func flush() {
        cache.withLock { CVMetalTextureCacheFlush($0, 0) }
    }
}
