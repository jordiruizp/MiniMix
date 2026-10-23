import CoreVideo
import Metal

extension FrameCodeReader {
    /// Lee el código de un CVPixelBuffer (BGRA/RGBA o 4:2:0 biplanar) sin convertir el fotograma entero.
    public static func read(pixelBuffer: CVPixelBuffer, layout: FrameCodeLayout? = nil) throws -> FrameCodeReading {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sampler = try PixelBufferLumaSampler(pixelBuffer)
        return read(sampler, layout: layout)
    }

    /// Lee el código de una textura `bgra8Unorm`/`rgba8Unorm` (privada o compartida).
    public static func read(texture: MTLTexture, layout: FrameCodeLayout? = nil) throws -> FrameCodeReading {
        read(try RGBAImage(texture: texture), layout: layout)
    }
}

/// Muestreador de luminancia sobre un CVPixelBuffer ya bloqueado (válido solo mientras lo esté).
struct PixelBufferLumaSampler: LumaSampling {
    let width: Int
    let height: Int
    private let base: UnsafePointer<UInt8>
    private let bytesPerRow: Int
    private let kind: Kind

    private enum Kind { case bgra, rgba, lumaVideoRange, lumaFullRange }

    init(_ buffer: CVPixelBuffer) throws {
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let pointer: UnsafeMutableRawPointer?
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA:
            kind = format == kCVPixelFormatType_32BGRA ? .bgra : .rgba
            pointer = CVPixelBufferGetBaseAddress(buffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            kind = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? .lumaVideoRange : .lumaFullRange
            pointer = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        default:
            throw RGBAImageError.unsupportedPixelFormat(String(format: "0x%08x", format))
        }
        guard let pointer else { throw RGBAImageError.unreadable("base address") }
        base = UnsafePointer(pointer.assumingMemoryBound(to: UInt8.self))
    }

    func luma(x: Int, y: Int) -> Double {
        switch kind {
        case .lumaVideoRange:
            return min(1, max(0, (Double(base[y * bytesPerRow + x]) - 16) / 219))
        case .lumaFullRange:
            return Double(base[y * bytesPerRow + x]) / 255
        case .bgra, .rgba:
            let i = y * bytesPerRow + x * 4
            let (r, b) = kind == .bgra ? (base[i + 2], base[i]) : (base[i], base[i + 2])
            return (0.2126 * Double(r) + 0.7152 * Double(base[i + 1]) + 0.0722 * Double(b)) / 255
        }
    }
}
