import CoreMocks
import Foundation
import Metal

/// Lectura del código de fotograma de TestMedia (ver `TestMedia/manifest.json`, `frameCode`).
/// Port mínimo del lector de `Tests/Sources/TestSupport/FrameCode.swift` (H): el paquete Media
/// no puede depender del paquete de integración (que depende de Media).
///
/// Solo se copia a CPU la tira del código (abajo a la izquierda, 25 × 3 celdas), con un blit
/// asíncrono: el bucle de ticks no espera a la GPU.
struct FrameCodeReading: Sendable {
    /// `clipID << 11 | frame`, nil si no hay código legible.
    var value: Int?
    /// Luminancia media de la región leída (0…1).
    var luma: Double

    var clipID: Int? { value.map { $0 >> 11 } }
    var frame: Int? { value.map { $0 & 0x7FF } }
}

/// `@unchecked Sendable` (solo tests): `MTLDevice`/`MTLCommandQueue` son seguros entre hilos y las
/// lecturas van tras `Locked`.
final class FrameCodeProbe: @unchecked Sendable {
    private let readings = Locked([Int: FrameCodeReading]())
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    /// Programa la lectura del fotograma `index` (asíncrona).
    func read(_ texture: MTLTexture?, index: Int) {
        guard let texture else {
            readings.withLock { $0[index] = FrameCodeReading(value: nil, luma: 0) }
            return
        }
        let s = min(texture.width, texture.height) / 45
        let width = min(texture.width, max(1, 25 * s))
        let height = min(texture.height, max(1, 3 * s))
        let originY = texture.height - height
        let rowBytes = width * 4
        guard let made = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        // El búfer solo se lee en el completado, cuando la GPU ya escribió.
        nonisolated(unsafe) let buffer = made
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: originY, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        let readings = readings
        let bgra = texture.pixelFormat != .rgba8Unorm && texture.pixelFormat != .rgba8Unorm_srgb
        commandBuffer.addCompletedHandler { _ in
            let reading = Self.decode(buffer.contents().assumingMemoryBound(to: UInt8.self),
                                      width: width, height: height, cell: s, bgra: bgra)
            readings.withLock { $0[index] = reading }
        }
        commandBuffer.commit()
    }

    func results(count: Int) -> [FrameCodeReading?] {
        readings.withLock { r in (0..<count).map { r[$0] } }
    }

    // MARK: Decodificación

    private static func decode(_ data: UnsafePointer<UInt8>, width: Int, height: Int, cell s: Int, bgra: Bool) -> FrameCodeReading {
        func luma(_ x: Int, _ y: Int) -> Double {
            let p = data + (y * width + x) * 4
            let (r, g, b) = bgra ? (p[2], p[1], p[0]) : (p[0], p[1], p[2])
            return (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
        }
        func mean(x0: Int, y0: Int, w: Int, h: Int, grid: Int = 8) -> Double {
            var sum = 0.0
            var count = 0
            for j in 0..<grid {
                for i in 0..<grid {
                    let x = x0 + w / 4 + (w / 2) * (2 * i + 1) / (2 * grid)
                    let y = y0 + h / 4 + (h / 2) * (2 * j + 1) / (2 * grid)
                    guard x >= 0, y >= 0, x < width, y < height else { continue }
                    sum += luma(x, y)
                    count += 1
                }
            }
            return count == 0 ? 0 : sum / Double(count)
        }
        let average = mean(x0: -width / 2, y0: -height / 2, w: width * 2, h: height * 2, grid: 16)
        guard s >= 4, width >= 24 * s else { return FrameCodeReading(value: nil, luma: average) }
        let levels = (0..<23).map { mean(x0: s * (1 + $0), y0: s, w: s, h: s) }
        let contrast = levels[0] - levels[1]
        let threshold = (levels[0] + levels[1]) / 2
        guard contrast >= 0.35, levels.allSatisfy({ abs($0 - threshold) >= 0.25 * contrast }) else {
            return FrameCodeReading(value: nil, luma: average)
        }
        let cells = levels.map { $0 > threshold }
        let value = (0..<16).reduce(0) { $0 | (cells[2 + $1] ? 1 << $1 : 0) }
        guard expectedCells(value) == cells else { return FrameCodeReading(value: nil, luma: average) }
        return FrameCodeReading(value: value, luma: average)
    }

    static func expectedCells(_ value: Int) -> [Bool] {
        let bits = (0..<16).map { value >> $0 & 1 == 1 }
        let parity = bits.filter { $0 }.count % 2 == 1
        var crc = 0
        for bit in stride(from: 15, through: 0, by: -1) {
            let feedback = (crc >> 3 & 1) ^ (value >> bit & 1)
            crc = (crc << 1) & 0xF
            if feedback == 1 { crc ^= 0x3 }
        }
        return [true, false] + bits + [parity] + (0..<4).map { crc >> $0 & 1 == 1 }
    }
}
