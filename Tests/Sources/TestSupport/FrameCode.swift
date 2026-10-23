import CoreGraphics
import Foundation

/// Código de fotograma legible por máquina que `Tools/generate-testmedia.sh` dibuja en cada
/// vídeo/imagen de TestMedia (ver `TestMedia/manifest.json`, clave `frameCode`).
///
/// Tira de 23 celdas cuadradas abajo a la izquierda:
/// `[blanco][negro][bit0…bit15][paridad par][crc0…crc3]` (CRC-4-ITU, x⁴+x+1, init 0, MSB→LSB).
/// `value = clipID << 11 | frameIndex`.
public struct FrameCode: Hashable, Sendable, CustomStringConvertible {
    public static let dataBits = 16
    public static let frameBits = 11
    public static let cellCount = 23
    public static let maxValue = (1 << dataBits) - 1

    public let value: Int

    public init(value: Int) {
        precondition((0...Self.maxValue).contains(value), "FrameCode fuera de rango: \(value)")
        self.value = value
    }

    public init(clipID: Int, frameIndex: Int) {
        precondition(frameIndex < 1 << Self.frameBits && clipID < 1 << (Self.dataBits - Self.frameBits))
        self.init(value: clipID << Self.frameBits | frameIndex)
    }

    public var clipID: Int { value >> Self.frameBits }
    public var frameIndex: Int { value & ((1 << Self.frameBits) - 1) }
    public var description: String { "clip \(clipID) frame \(frameIndex)" }

    /// Estado (blanco = true) de las 23 celdas.
    public var cells: [Bool] {
        let bits = (0..<Self.dataBits).map { value >> $0 & 1 == 1 }
        let parity = bits.filter { $0 }.count % 2 == 1
        let crc = Self.crc4(value)
        return [true, false] + bits + [parity] + (0..<4).map { crc >> $0 & 1 == 1 }
    }

    /// CRC-4-ITU (x⁴+x+1, init 0) de los 16 bits, de MSB a LSB. Igual que `crc4` del generador.
    public static func crc4(_ value: Int) -> Int {
        var crc = 0
        for bit in stride(from: dataBits - 1, through: 0, by: -1) {
            let feedback = (crc >> 3 & 1) ^ (value >> bit & 1)
            crc = (crc << 1) & 0xF
            if feedback == 1 { crc ^= 0x3 }
        }
        return crc
    }
}

/// Geometría del código y de la claqueta dentro del rectángulo que ocupa la fuente
/// (todo el búfer, o la zona donde el compositor la encajó con fit/fill).
public struct FrameCodeLayout: Sendable {
    /// Rectángulo de la fuente en píxeles del búfer (origen arriba a la izquierda).
    public let contentRect: CGRect

    public init(contentRect: CGRect) { self.contentRect = contentRect }
    public init(width: Int, height: Int) {
        self.init(contentRect: CGRect(x: 0, y: 0, width: width, height: height))
    }

    public var cellSize: CGFloat { min(contentRect.width, contentRect.height) / 45 }

    public func cellRect(_ index: Int) -> CGRect {
        let s = cellSize
        return CGRect(x: contentRect.minX + s * CGFloat(1 + index), y: contentRect.maxY - 2 * s, width: s, height: s)
    }

    /// Fondo negro que rodea la tira.
    public var stripBackground: CGRect {
        let s = cellSize
        return CGRect(x: contentRect.minX + s / 2, y: contentRect.maxY - 2.5 * s, width: 24 * s, height: 2 * s)
    }

    /// Parche de la claqueta (blanco en el primer frame de cada segundo).
    public var clapRect: CGRect {
        let s = cellSize
        return CGRect(x: contentRect.maxX - 5 * s, y: contentRect.maxY - 5 * s, width: 4 * s, height: 4 * s)
    }
}

/// Acceso a la luminancia (0…1) de un fotograma, sea cual sea su almacenamiento.
public protocol LumaSampling {
    var width: Int { get }
    var height: Int { get }
    func luma(x: Int, y: Int) -> Double
}

extension LumaSampling {
    /// Media de la luminancia en el 50 % central de `rect` (rejilla de hasta 8×8 muestras).
    public func meanLuma(in rect: CGRect, inset: CGFloat = 0.25, grid: Int = 8) -> Double {
        let inner = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        var sum = 0.0
        var count = 0
        for j in 0..<grid {
            for i in 0..<grid {
                let x = Int(inner.minX + inner.width * (CGFloat(i) + 0.5) / CGFloat(grid))
                let y = Int(inner.minY + inner.height * (CGFloat(j) + 0.5) / CGFloat(grid))
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                sum += luma(x: x, y: y)
                count += 1
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }

    /// Luminancia media de todo el fotograma (detección de negros).
    public var averageLuma: Double {
        meanLuma(in: CGRect(x: 0, y: 0, width: width, height: height), inset: 0, grid: 32)
    }
}

/// Resultado de leer un fotograma.
public struct FrameCodeReading: Hashable, Sendable {
    /// nil si no hay código legible (negro, otra imagen, transición a medias…).
    public var code: FrameCode?
    /// Parche de la claqueta encendido.
    public var clapLit: Bool
    /// Luminancia media del fotograma completo (0…1).
    public var averageLuma: Double
    /// Contraste entre las celdas de calibración blanca y negra (0…1).
    public var contrast: Double

    /// Heurística de «fotograma negro» para tests gapless.
    public var isBlack: Bool { averageLuma < 0.03 }
}

/// Lector del código de fotograma.
///
/// Formatos soportados:
/// - `RGBAImage` (RGBA8) y cualquier `LumaSampling`.
/// - `CVPixelBuffer`: `kCVPixelFormatType_32BGRA`, `kCVPixelFormatType_32RGBA` y 4:2:0 biplanar **8 bit**
///   (`420YpCbCr8BiPlanarVideoRange` / `FullRange`; solo se lee el plano de luma).
/// - `MTLTexture`: `bgra8Unorm(_srgb)` y `rgba8Unorm(_srgb)`, compartida o privada (se copia con un blit).
///
/// No soportados (lanzan `RGBAImageError.unsupportedPixelFormat`): 10 bit (`x420`, `p010`), 4:2:2,
/// medio flotante (`rgba16Float`) ni ProRes RAW. Para leerlos, pide a AVAssetReader/al compositor BGRA
/// u 8 bit 4:2:0.
public enum FrameCodeReader {
    /// Contraste mínimo entre las celdas de calibración para aceptar el código.
    public static let minimumContrast = 0.35
    /// Distancia mínima de cada celda al umbral, en fracción del contraste. En un fundido entre dos
    /// códigos, las celdas que difieren quedan cerca del umbral y la lectura se descarta.
    public static let minimumCellMargin = 0.25

    public static func read(_ frame: some LumaSampling, layout: FrameCodeLayout? = nil) -> FrameCodeReading {
        let layout = layout ?? FrameCodeLayout(width: frame.width, height: frame.height)
        let white = frame.meanLuma(in: layout.cellRect(0))
        let black = frame.meanLuma(in: layout.cellRect(1))
        let contrast = white - black
        let threshold = (white + black) / 2
        let clap = frame.meanLuma(in: layout.clapRect) > max(threshold, 0.5)
        var reading = FrameCodeReading(code: nil, clapLit: clap, averageLuma: frame.averageLuma, contrast: contrast)
        guard contrast >= minimumContrast else { return reading }
        let levels = (0..<FrameCode.cellCount).map { frame.meanLuma(in: layout.cellRect($0)) }
        guard levels.allSatisfy({ abs($0 - threshold) >= minimumCellMargin * contrast }) else { return reading }
        let cells = levels.map { $0 > threshold }
        let value = (0..<FrameCode.dataBits).reduce(0) { $0 | (cells[2 + $1] ? 1 << $1 : 0) }
        let code = FrameCode(value: value)
        // Paridad y CRC: las celdas leídas deben ser exactamente las que dibujaría ese valor.
        guard code.cells == cells else { return reading }
        reading.code = code
        return reading
    }
}

/// Dibuja el código (y la claqueta) igual que el generador; útil para tests sin TestMedia.
public enum FrameCodeWriter {
    public static func draw(_ code: FrameCode, clapLit: Bool = false, into image: inout RGBAImage,
                            layout: FrameCodeLayout? = nil) {
        let layout = layout ?? FrameCodeLayout(width: image.width, height: image.height)
        image.fill(layout.stripBackground, with: .black)
        for (index, isWhite) in code.cells.enumerated() where isWhite {
            image.fill(layout.cellRect(index), with: .white)
        }
        image.fill(layout.clapRect, with: clapLit ? .white : .black)
    }
}
