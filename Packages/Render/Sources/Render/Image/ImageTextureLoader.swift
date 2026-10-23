import Core
import CoreGraphics
import Foundation
import ImageIO
import Metal

public enum ImageTextureLoaderError: Error, Equatable, Sendable {
    case unreadable(URL)
    case decodeFailed(URL)
    case allocationFailed
    case gpuUploadFailed
}

/// Carga imágenes fijas (PNG, JPEG, HEIC, TIFF…) a `MTLTexture` (T22).
///
/// - Decodifica **reduciendo** al tamaño máximo pedido en la propia decodificación
///   (`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize`):
///   una foto de 8000×8000 nunca se materializa a tamaño completo.
/// - Aplica la orientación EXIF.
/// - Convierte a sRGB, BGRA8 con alfa **premultiplicado** (el convenio del compositor).
/// - Sube los píxeles una sola vez a una textura `.private` / `.shaderRead` con un blit,
///   esperando la GPU de forma asíncrona (sin `waitUntilCompleted`).
///
/// Es E/S: no llamar desde el hilo de render. La decodificación y la conversión
/// (bloqueantes) se hacen en una cola serie propia, fuera del pool cooperativo de
/// Swift Concurrency; al ser serie, como mucho hay una imagen grande en
/// memoria de paso a la vez.
public final class ImageTextureLoader: Sendable {
    public let context: MetalContext

    static let decodeQueue = DispatchQueue(label: "MiniMix.ImageDecode", qos: .userInitiated)
    private static let decodeQueueKey = DispatchSpecificKey<Bool>()
    /// Decodificaciones hechas en `decodeQueue` (para tests).
    static let dedicatedDecodes = UnfairLocked(0)

    /// Píxeles BGRA premultiplicados en un buffer compartido, listos para el blit.
    private struct Staged: @unchecked Sendable {
        let buffer: MTLBuffer
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    public init(context: MetalContext) {
        self.context = context
        Self.decodeQueue.setSpecific(key: Self.decodeQueueKey, value: true)
    }

    public func loadTexture(from url: URL, maxSize: PixelSize) async throws -> MTLTexture {
        let device = context.device
        let staged: Staged = try await withCheckedThrowingContinuation { continuation in
            Self.decodeQueue.async {
                continuation.resume(with: Result { try Self.decodeAndStage(url: url, maxSize: maxSize, device: device) })
            }
        }
        return try await upload(staged)
    }

    /// Tamaño (ya orientado) que tendrá la imagen al cargarla con `maxSize`.
    public static func targetSize(of url: URL, maxSize: PixelSize) throws -> PixelSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageTextureLoaderError.unreadable(url)
        }
        guard let size = orientedSize(source) else { throw ImageTextureLoaderError.decodeFailed(url) }
        return fitted(size, in: maxSize)
    }

    // MARK: - Decodificación

    static func decode(url: URL, maxSize: PixelSize) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ImageTextureLoaderError.unreadable(url)
        }
        guard let size = orientedSize(source) else { throw ImageTextureLoaderError.decodeFailed(url) }
        let target = fitted(size, in: maxSize)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageTextureLoaderError.decodeFailed(url)
        }
        return image
    }

    /// Tamaño en píxeles tras aplicar la orientación EXIF.
    static func orientedSize(_ source: CGImageSource) -> PixelSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // 5…8 = rotaciones de 90°: se intercambian ancho y alto.
        return (5...8).contains(orientation)
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
    }

    /// Escala `size` para que quepa en `maxSize` conservando el aspecto (nunca amplía).
    static func fitted(_ size: PixelSize, in maxSize: PixelSize) -> PixelSize {
        let scale = min(1, Double(max(1, maxSize.width)) / Double(size.width),
                        Double(max(1, maxSize.height)) / Double(size.height))
        return PixelSize(width: max(1, Int((Double(size.width) * scale).rounded())),
                         height: max(1, Int((Double(size.height) * scale).rounded())))
    }

    // MARK: - Subida a GPU

    private static func decodeAndStage(url: URL, maxSize: PixelSize, device: MTLDevice) throws -> Staged {
        if DispatchQueue.getSpecific(key: decodeQueueKey) == true { dedicatedDecodes.withLock { $0 += 1 } }
        let image = try decode(url: url, maxSize: maxSize)
        let width = image.width
        let height = image.height
        let bytesPerRow = (width * 4 + 255) & ~255
        guard let staging = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(
                data: staging.contents(), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ImageTextureLoaderError.allocationFailed }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        cg.clear(rect)
        cg.interpolationQuality = .high
        cg.draw(image, in: rect)
        return Staged(buffer: staging, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private func upload(_ staged: Staged) async throws -> MTLTexture {
        let device = context.device
        let (staging, width, height, bytesPerRow) = (staged.buffer, staged.width, staged.height, staged.bytesPerRow)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw ImageTextureLoaderError.allocationFailed
        }
        texture.label = "MiniMix.Image"
        commandBuffer.label = "MiniMix.ImageUpload"
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
                  sourceBytesPerImage: bytesPerRow * height, sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        let ok: Bool = await withCheckedContinuation { continuation in
            // El buffer de paso vive hasta que termina la copia.
            nonisolated(unsafe) let staging = staging
            commandBuffer.addCompletedHandler { buffer in
                withExtendedLifetime(staging) {
                    continuation.resume(returning: buffer.status == .completed)
                }
            }
            commandBuffer.commit()
        }
        guard ok else { throw ImageTextureLoaderError.gpuUploadFailed }
        return texture
    }
}
