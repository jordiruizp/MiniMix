import Core
import CoreMocks
import Foundation
import Metal
@testable import Media

/// Utilidades de los tests de playlist (sin TestSupport de H: el paquete Media no puede
/// depender del paquete de integración, que depende de Media).
enum PlaylistTesting {
    static let red = RGBAColor(red: 1, green: 0, blue: 0)
    static let green = RGBAColor(red: 0, green: 1, blue: 0)
    static let blue = RGBAColor(red: 0, green: 0, blue: 1)

    static func environment(frameRate: FrameRate = .fps60, canvas: PixelSize = PixelSize(width: 64, height: 36),
                            preloadLead: Double = 3) -> PlaylistEnvironment {
        PlaylistEnvironment(context: GPU.context!, clock: MockClock(frameRate: frameRate), canvasSize: canvas,
                            preloadLead: preloadLead, releaseDelay: 0.05)
    }

    static func colors(_ colors: [RGBAColor], seconds: Double = 1) -> [PlaylistItem] {
        colors.map { PlaylistItem(source: .color($0), duration: seconds) }
    }

    /// Lee en CPU (solo tests) el píxel central de una textura, en 0…1 (RGBA).
    static func pixel(_ texture: MTLTexture?, x: Int? = nil, y: Int? = nil) -> SIMD4<Double>? {
        guard let texture, let context = GPU.context,
              let buffer = context.device.makeBuffer(length: 4, options: .storageModeShared),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: x ?? texture.width / 2, y: y ?? texture.height / 2, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        let bgra = (0..<4).map { Double(bytes[$0]) / 255 }
        let isBGRA = texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb
        return isBGRA ? SIMD4(bgra[2], bgra[1], bgra[0], bgra[3]) : SIMD4(bgra[0], bgra[1], bgra[2], bgra[3])
    }

    static func isColor(_ value: SIMD4<Double>?, _ color: RGBAColor, tolerance: Double = 0.02) -> Bool {
        guard let value else { return false }
        return abs(value.x - color.red) <= tolerance && abs(value.y - color.green) <= tolerance
            && abs(value.z - color.blue) <= tolerance
    }

    /// ΔE CIE76 entre dos colores sRGB codificados (0…1).
    static func deltaE(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = lab(a)
        let lb = lab(b)
        return ((la.x - lb.x) * (la.x - lb.x) + (la.y - lb.y) * (la.y - lb.y) + (la.z - lb.z) * (la.z - lb.z)).squareRoot()
    }

    private static func lab(_ srgb: SIMD3<Double>) -> SIMD3<Double> {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(srgb.x), g = linear(srgb.y), b = linear(srgb.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
}

/// Reproduce una playlist con ticks manuales (60 Hz por defecto) y registra lo que se ve.
struct ManualDriver {
    let playlist: PlaylistInput
    let frame: Double
    var time: HostTime

    init(_ playlist: PlaylistInput, frameRate: FrameRate = .fps60, start: Double = 100) {
        self.playlist = playlist
        frame = frameRate.frameDuration
        time = HostTime(seconds: start)
    }

    /// Avanza `count` ticks; tras cada uno espera a la cola y a las cargas, y devuelve la
    /// textura de ese tick.
    mutating func run(_ count: Int, waitLoads: Bool = true,
                      onFrame: (Int, MTLTexture?) -> Void = { _, _ in }) async {
        for index in 0..<count {
            time = time + frame
            playlist.tick(time)
            if waitLoads { await playlist.waitUntilLoaded() } else { await playlist.settle() }
            onFrame(index, playlist.texture(for: time))
        }
    }
}
