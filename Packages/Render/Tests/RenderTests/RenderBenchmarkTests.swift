import Core
import Foundation
import Metal
import Testing
@testable import Render

/// Benchmark corto (T20): N fotogramas 1080p sin ventana, tiempo de GPU por
/// command buffer (gpuEndTime − gpuStartTime). Cada fotograma = composición
/// 1080p (fundido de dos fuentes 1080p) + dos monitores 960×540 (PVW y PGM).
@Suite("Benchmark render 1080p", .enabled(if: hasGPU))
struct RenderBenchmarkTests {
    static let frames = 120
    static let budgetMs = 1000.0 / 60

    @Test func compositorAndMonitorsHold60fps() throws {
        let context = GPU.context
        let compositor = try Compositor(context: context)
        let monitor = try MonitorRenderer(context: context)
        let pool = TexturePool(device: context.device)
        let canvas = PixelSize.hd1080

        // Fuentes 1080p privadas, rellenas en GPU.
        let sources = [RGBAColor(red: 1, green: 0.5, blue: 0), RGBAColor(red: 0, green: 0.3, blue: 1)].map { color in
            let texture = pool.dequeue(width: canvas.width, height: canvas.height)!
            GPU.run { context.encodeSolidColor(color, into: texture, commandBuffer: $0) }
            return texture
        }
        let monitors = (0..<2).map { _ in pool.dequeue(width: 960, height: 540)! }
        let gpuTimes = SampleBox()

        // Como en producción: como máximo 3 fotogramas en vuelo (triple buffer).
        let inFlight = DispatchSemaphore(value: 3)
        var last: MTLCommandBuffer?
        for index in 0..<Self.frames {
            inFlight.wait()
            let commandBuffer = context.commandQueue.makeCommandBuffer()!
            let target = pool.dequeue(width: canvas.width, height: canvas.height)!
            let mix = Float(TransitionCurve.videoMix(Double(index) / Double(Self.frames - 1)))
            compositor.encode(CompositorFrame(a: sources[0], b: sources[1], mix: mix, kind: .fade),
                              into: target, commandBuffer: commandBuffer)
            monitor.encode(sources[1], into: monitors[0], border: MonitorBorder(color: RGBAColor(red: 0, green: 1, blue: 0), width: 6),
                           commandBuffer: commandBuffer)
            monitor.encode(target, into: monitors[1], border: MonitorBorder(color: RGBAColor(red: 1, green: 0, blue: 0), width: 6),
                           commandBuffer: commandBuffer)
            pool.recycle(target, after: commandBuffer)
            commandBuffer.addCompletedHandler { buffer in
                gpuTimes.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
                inFlight.signal()
            }
            commandBuffer.commit()
            last = commandBuffer
        }
        last?.waitUntilCompleted()
        _ = waitUntil { gpuTimes.values.count >= Self.frames }

        let samples = gpuTimes.values
        #expect(samples.count == Self.frames)
        let mean = samples.reduce(0, +) / Double(max(1, samples.count))
        let p99 = percentile(samples, 99)
        print("[T20] \(samples.count) fotogramas 1080p (compositor + 2 monitores 960×540): "
              + "GPU media \(String(format: "%.3f", mean)) ms, p99 \(String(format: "%.3f", p99)) ms, "
              + "máx \(String(format: "%.3f", samples.max() ?? 0)) ms (presupuesto 60 fps: "
              + "\(String(format: "%.2f", Self.budgetMs)) ms); stats \(compositor.stats)")
        #expect(mean < Self.budgetMs)
        #expect(p99 < Self.budgetMs)
        // El pool rota destinos en lugar de crear uno por fotograma.
        #expect(pool.cachedCount <= 4)
    }
}

final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    func append(_ value: Double) { lock.withLock { samples.append(value) } }
    var values: [Double] { lock.withLock { samples } }
}
