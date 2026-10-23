import Core
import Foundation
import Metal
import Testing
@testable import Render

/// Los tests de GPU se desactivan (salen limpiamente) si no hay dispositivo Metal.
let hasGPU = MetalContext.shared != nil

/// Los tests de rendimiento miden y escriben siempre, pero solo exigen el objetivo
/// fuera de CI (`CI` sin definir): los runners macOS de GitHub usan GPU paravirtualizada.
let enforcesPerformanceTargets = ProcessInfo.processInfo.environment["CI"] == nil

/// Píxel BGRA8 leído de una textura.
struct Pixel: Equatable, CustomStringConvertible {
    var red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    var description: String { "(\(red), \(green), \(blue), \(alpha))" }
}

/// Color esperado en 0…255 (puede ser fraccionario, p. ej. 127,5).
struct Expected {
    var red: Double, green: Double, blue: Double, alpha: Double = 255

    static let black = Expected(red: 0, green: 0, blue: 0)
    static let red = Expected(red: 255, green: 0, blue: 0)
    static let green = Expected(red: 0, green: 255, blue: 0)
    static let blue = Expected(red: 0, green: 0, blue: 255)
    static let magenta = Expected(red: 255, green: 0, blue: 255)
}

enum GPU {
    static var context: MetalContext { MetalContext.shared! }

    /// Textura `.shared` rellenada en CPU (solo tests) con BGRA premultiplicado.
    static func texture(width: Int, height: Int, usage: MTLTextureUsage = .shaderRead,
                        _ pixel: (Int, Int) -> Pixel) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                            mipmapped: false)
        desc.usage = usage
        desc.storageMode = .shared
        let texture = context.device.makeTexture(descriptor: desc)!
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = p.blue
                bytes[i + 1] = p.green
                bytes[i + 2] = p.red
                bytes[i + 3] = p.alpha
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    static func solid(width: Int, height: Int, _ pixel: Pixel) -> MTLTexture {
        texture(width: width, height: height) { _, _ in pixel }
    }

    /// Destino de render legible desde CPU.
    static func target(width: Int, height: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        return context.device.makeTexture(descriptor: desc)!
    }

    /// Codifica con `body`, envía y espera (solo tests).
    static func run(_ body: (MTLCommandBuffer) -> Void) {
        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        body(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Lee todos los píxeles (copia a una textura `.shared` si hace falta). Solo tests.
    static func read(_ texture: MTLTexture) -> [Pixel] {
        var readable = texture
        if texture.storageMode == .private {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
            desc.storageMode = .shared
            readable = context.device.makeTexture(descriptor: desc)!
            run { commandBuffer in
                let blit = commandBuffer.makeBlitCommandEncoder()!
                blit.copy(from: texture, to: readable)
                blit.endEncoding()
            }
        }
        let width = readable.width
        let height = readable.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        readable.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return stride(from: 0, to: bytes.count, by: 4).map {
            Pixel(red: bytes[$0 + 2], green: bytes[$0 + 1], blue: bytes[$0], alpha: bytes[$0 + 3])
        }
    }
}

/// Resultado de comparar una textura con valores esperados.
struct SnapshotResult: CustomStringConvertible {
    var maxDeltaE: Double = 0
    var maxAlphaError: Double = 0
    var worst: String = ""
    var compared = 0
    var description: String { "ΔE máx \(maxDeltaE) α err \(maxAlphaError) en \(worst) (\(compared) px)" }
}

/// Compara cada píxel con `expected(x, y)` (nil = no comparar) usando ΔE CIE76 en Lab
/// (sRGB → XYZ D65 → Lab). Solo tests.
func compare(_ texture: MTLTexture, _ expected: (Int, Int) -> Expected?) -> SnapshotResult {
    let pixels = GPU.read(texture)
    var result = SnapshotResult()
    for y in 0..<texture.height {
        for x in 0..<texture.width {
            guard let want = expected(x, y) else { continue }
            let got = pixels[y * texture.width + x]
            let deltaE = ColorMath.deltaE(
                SIMD3(Double(got.red), Double(got.green), Double(got.blue)), SIMD3(want.red, want.green, want.blue))
            let alphaError = abs(Double(got.alpha) - want.alpha)
            result.compared += 1
            if deltaE > result.maxDeltaE || alphaError > result.maxAlphaError {
                result.worst = "(\(x), \(y)) got \(got) want (\(want.red), \(want.green), \(want.blue), \(want.alpha))"
            }
            result.maxDeltaE = max(result.maxDeltaE, deltaE)
            result.maxAlphaError = max(result.maxAlphaError, alphaError)
        }
    }
    return result
}

enum ColorMath {
    static func deltaE(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        let diff = lab(lhs) - lab(rhs)
        return (diff * diff).sum().squareRoot()
    }

    /// sRGB 0…255 → Lab (D65).
    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        func linear(_ c: Double) -> Double {
            let v = c / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(rgb.x)
        let g = linear(rgb.y)
        let b = linear(rgb.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x)
        let fy = f(y)
        let fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}

/// Percentil (0…100) de una lista de muestras.
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count - 1)).rounded(.up))
    return sorted[min(sorted.count - 1, max(0, rank))]
}

/// Espera activa (solo tests) a que se cumpla `condition`, hasta `timeout` segundos
/// (holgado: la máquina la comparten varios procesos).
/// Para efectos de completion handlers de Metal, que llegan tras `waitUntilCompleted`.
func waitUntil(timeout: Double = 4, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        usleep(1_000)
    }
    return true
}
