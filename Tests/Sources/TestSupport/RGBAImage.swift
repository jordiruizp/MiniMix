import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Imagen RGBA8 (sRGB, alfa no premultiplicado) en memoria, para comparar y leer fotogramas en
/// tests. Las copias a CPU solo se permiten aquí (tests), nunca en el camino de render.
public struct RGBAImage: Equatable, Sendable, LumaSampling {
    public struct Pixel: Equatable, Sendable {
        public var r, g, b, a: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
        public static let black = Pixel(r: 0, g: 0, b: 0)
        public static let white = Pixel(r: 255, g: 255, b: 255)
    }

    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, filas contiguas.
    public var bytes: [UInt8]

    public init(width: Int, height: Int, fill: Pixel = .black) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        self.fill(CGRect(x: 0, y: 0, width: width, height: height), with: fill)
    }

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public subscript(x: Int, y: Int) -> Pixel {
        get {
            let i = (y * width + x) * 4
            return Pixel(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            bytes[i] = newValue.r
            bytes[i + 1] = newValue.g
            bytes[i + 2] = newValue.b
            bytes[i + 3] = newValue.a
        }
    }

    /// Rellena `rect` (redondeado a píxeles enteros y recortado a la imagen).
    public mutating func fill(_ rect: CGRect, with pixel: Pixel) {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, !clipped.isEmpty else { return }
        for y in Int(clipped.minY)..<Int(clipped.maxY) {
            for x in Int(clipped.minX)..<Int(clipped.maxX) { self[x, y] = pixel }
        }
    }

    /// Luma Rec.709 sobre valores con gamma (0…1).
    public func luma(x: Int, y: Int) -> Double {
        let i = (y * width + x) * 4
        return (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255
    }
}

// MARK: - CoreGraphics / ImageIO

public enum RGBAImageError: Error, Equatable {
    case unreadable(String)
    case unsupportedPixelFormat(String)
    case metal(String)
}

extension RGBAImage {
    public init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw RGBAImageError.unreadable("CGContext") }
        // Deshacer la premultiplicación para guardar alfa recto.
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] != 0 && bytes[i + 3] != 255 {
            let alpha = Double(bytes[i + 3]) / 255
            for c in 0..<3 { bytes[i + c] = UInt8(min(255, (Double(bytes[i + c]) / alpha).rounded())) }
        }
        self.init(width: width, height: height, bytes: bytes)
    }

    /// Carga PNG/JPEG/HEIC/TIFF con ImageIO.
    public init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RGBAImageError.unreadable(url.path)
        }
        try self.init(cgImage: image)
    }

    public func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Guarda como PNG (referencias de snapshots, artefactos de fallos).
    public func writePNG(to url: URL) throws {
        guard let image = makeCGImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RGBAImageError.unreadable(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RGBAImageError.unreadable(url.path) }
    }
}

// MARK: - CVPixelBuffer

extension RGBAImage {
    /// Copia un CVPixelBuffer BGRA/RGBA o YpCbCr 4:2:0 biplanar 8 bit (vídeo o rango completo, BT.709).
    public init(pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var out = [UInt8](repeating: 255, count: width * height * 4)
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw RGBAImageError.unreadable("base") }
            let src = base.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let swap = format == kCVPixelFormatType_32BGRA
            for y in 0..<height {
                for x in 0..<width {
                    let s = y * bpr + x * 4
                    let d = (y * width + x) * 4
                    out[d] = src[s + (swap ? 2 : 0)]
                    out[d + 1] = src[s + 1]
                    out[d + 2] = src[s + (swap ? 0 : 2)]
                    out[d + 3] = src[s + 3]
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let video = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
                throw RGBAImageError.unreadable("planes")
            }
            let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
            let cPlane = cBase.assumingMemoryBound(to: UInt8.self)
            let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let cBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            for y in 0..<height {
                for x in 0..<width {
                    let c = (y / 2) * cBpr + (x / 2) * 2
                    let rgb = Self.bt709(y: yPlane[y * yBpr + x], cb: cPlane[c], cr: cPlane[c + 1], videoRange: video)
                    let d = (y * width + x) * 4
                    out[d] = rgb.r
                    out[d + 1] = rgb.g
                    out[d + 2] = rgb.b
                }
            }
        default:
            throw RGBAImageError.unsupportedPixelFormat(String(format: "0x%08x", format))
        }
        self.init(width: width, height: height, bytes: out)
    }

    private static func bt709(y: UInt8, cb: UInt8, cr: UInt8, videoRange: Bool) -> Pixel {
        let luma = videoRange ? (Double(y) - 16) / 219 : Double(y) / 255
        let scale = videoRange ? 224.0 : 255.0
        let pb = (Double(cb) - 128) / scale
        let pr = (Double(cr) - 128) / scale
        let r = luma + 1.5748 * pr
        let g = luma - 0.1873 * pb - 0.4681 * pr
        let b = luma + 1.8556 * pb
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return Pixel(r: q(r), g: q(g), b: q(b))
    }

    /// Crea un CVPixelBuffer BGRA respaldado por IOSurface con el contenido de la imagen.
    public func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw RGBAImageError.unreadable("CVPixelBufferCreate \(status)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let dst = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let s = (y * width + x) * 4
                let d = y * bpr + x * 4
                dst[d] = bytes[s + 2]
                dst[d + 1] = bytes[s + 1]
                dst[d + 2] = bytes[s]
                dst[d + 3] = bytes[s + 3]
            }
        }
        return buffer
    }
}

// MARK: - Metal

extension RGBAImage {
    /// Lee una textura `bgra8Unorm(_srgb)` o `rgba8Unorm(_srgb)`. Si es `.private`, la copia
    /// antes a una textura compartida con un blit (espera a la GPU: solo para tests).
    public init(texture: MTLTexture) throws {
        let bgra: Bool
        switch texture.pixelFormat {
        case .bgra8Unorm, .bgra8Unorm_srgb: bgra = true
        case .rgba8Unorm, .rgba8Unorm_srgb: bgra = false
        default: throw RGBAImageError.unsupportedPixelFormat("\(texture.pixelFormat.rawValue)")
        }
        let readable = texture.storageMode == .private ? try Self.sharedCopy(of: texture) : texture
        let width = readable.width
        let height = readable.height
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { buffer in
            readable.getBytes(buffer.baseAddress!, bytesPerRow: width * 4,
                              from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        if bgra {
            for i in stride(from: 0, to: out.count, by: 4) { out.swapAt(i, i + 2) }
        }
        self.init(width: width, height: height, bytes: out)
    }

    private static func sharedCopy(of texture: MTLTexture) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        desc.storageMode = .shared
        guard let copy = texture.device.makeTexture(descriptor: desc),
              let queue = texture.device.makeCommandQueue(),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { throw RGBAImageError.metal("blit setup") }
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return copy
    }

    /// Crea una textura compartida `bgra8Unorm` con el contenido de la imagen.
    public func makeTexture(device: MTLDevice, usage: MTLTextureUsage = [.shaderRead]) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = usage
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw RGBAImageError.metal("makeTexture") }
        var bgra = bytes
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        bgra.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }
}
