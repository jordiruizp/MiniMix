import Core
import Foundation
import Metal
import TestSupport

/// Ejecuta un `ScenarioConfig` contra un `PipelineFactory` y produce un `StressReport`.
///
/// Bucle de render: un fotograma por tick del `MasterClockProtocol`. En cada tick aplica las
/// acciones del escenario (cortes/fundidos, fin de item de playlist), avanza el switcher, pide
/// texturas a las fuentes (no bloqueante), codifica la composición y la envía a la GPU sin esperar.
public final class ScenarioRunner {
    /// Fotogramas en vuelo permitidos antes de descartar (triple búfer).
    public static let maxFramesInFlight = 3

    public let config: ScenarioConfig
    public let factory: PipelineFactory

    public init(config: ScenarioConfig, factory: PipelineFactory) {
        self.config = config
        self.factory = factory
    }

    private struct GPUCounters {
        var inFlight = 0
        var completed = 0
        var gpuTimesMs: [Double] = []
    }

    /// Medidas del bucle de render.
    private struct LoopMetrics {
        var startedAt = Date()
        var duration = 0.0
        var processed = 0
        var intervals: [Double] = []
        var deliveries: [Double] = []
        var cpuFrameTimes: [Double] = []
        var droppedByClock = 0
        var droppedByBackpressure = 0
        var memoryStart = 0.0
        var thermalStart = ThermalLevel.nominal
    }

    public func run() async throws -> StressReport {
        let canvas = config.canvas
        let frameDuration = canvas.frameRate.frameDuration
        let compositor = factory.makeCompositor()
        let queue = compositor?.device.makeCommandQueue()
        let target = compositor.flatMap { Self.makeTarget(device: $0.device, size: canvas.size) }
        var scene = try await Scene.make(config: config, factory: factory)

        let gpu = LockedBox(GPUCounters())
        let monitor = ResourceMonitor(interval: .seconds(config.sampleIntervalSeconds))
        var metrics = LoopMetrics(memoryStart: Double(ProcessMetrics.physFootprint() ?? 0) / 1_048_576,
                                  thermalStart: ProcessMetrics.thermalState)
        monitor.start()

        let clock = factory.makeClock(frameRate: canvas.frameRate)
        var lastTick: HostTime?
        var lastDelivery: ContinuousClock.Instant?
        var firstTick: HostTime?
        let wallStart = ContinuousClock.now
        clock.start()

        for await tick in clock.ticks {
            let frameStart = ContinuousClock.now
            if let lastDelivery { metrics.deliveries.append(lastDelivery.duration(to: frameStart).seconds * 1000) }
            lastDelivery = frameStart
            if firstTick == nil { firstTick = tick }
            if let last = lastTick {
                metrics.intervals.append((tick - last) * 1000)
                metrics.droppedByClock += max(0, Int(((tick - last) / frameDuration).rounded()) - 1)
            }
            lastTick = tick
            let elapsed = tick - (firstTick ?? tick)
            if elapsed + frameDuration / 2 >= config.durationSeconds { break }

            let frame = scene.advance(to: tick, elapsed: elapsed)
            metrics.processed += 1
            if let compositor, let queue, let target {
                if gpu.withLock({ $0.inFlight }) >= Self.maxFramesInFlight {
                    metrics.droppedByBackpressure += 1
                } else if let commands = queue.makeCommandBuffer() {
                    compositor.encode(frame, into: target, commandBuffer: commands)
                    gpu.withLock { $0.inFlight += 1 }
                    commands.addCompletedHandler { buffer in
                        let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                        gpu.withLock {
                            $0.inFlight -= 1
                            $0.completed += 1
                            $0.gpuTimesMs.append(ms)
                        }
                    }
                    commands.commit()
                }
            }
            metrics.cpuFrameTimes.append(frameStart.duration(to: .now).seconds * 1000)
        }
        clock.stop()
        metrics.duration = wallStart.duration(to: .now).seconds
        // Espera (acotada) a que la GPU termine lo que queda en vuelo.
        for _ in 0..<200 where gpu.withLock({ $0.inFlight }) > 0 { try await Task.sleep(for: .milliseconds(5)) }
        monitor.stop()
        scene.tearDown()
        return makeReport(metrics: metrics, gpu: gpu.withLock { $0 }, gpuName: compositor?.device.name,
                          samples: monitor.samples, events: scene.events)
    }

    private func makeReport(metrics: LoopMetrics, gpu: GPUCounters, gpuName: String?,
                            samples: [ResourceSample], events: StressReport.Events) -> StressReport {
        let canvas = config.canvas
        let rendered = gpuName == nil ? metrics.processed : gpu.completed
        let expected = Int((config.durationSeconds / canvas.frameRate.frameDuration).rounded())
        let footprints = samples.map(\.footprintMB)
        let cpu = samples.map(\.cpuPercent)
        let memoryEnd = Double(ProcessMetrics.physFootprint() ?? 0) / 1_048_576
        var thermalSeconds: [String: Double] = [:]
        for sample in samples { thermalSeconds[sample.thermal.rawValue, default: 0] += config.sampleIntervalSeconds }
        return StressReport(
            scenario: config, pipeline: factory.name, components: factory.components, gpu: gpuName,
            startedAt: metrics.startedAt, durationSeconds: metrics.duration, machine: MachineInfo.current(),
            frames: .init(targetFPS: canvas.frameRate.fps, measuredFPS: Double(rendered) / max(metrics.duration, 1e-9),
                          expected: expected, rendered: rendered, dropped: max(0, expected - rendered),
                          droppedByClock: metrics.droppedByClock, droppedByBackpressure: metrics.droppedByBackpressure),
            tickIntervalMs: .init(metrics.intervals), deliveryIntervalMs: .init(metrics.deliveries),
            gpuTimeMs: .init(gpu.gpuTimesMs),
            cpuFrameTimeMs: .init(metrics.cpuFrameTimes),
            memory: .init(startMB: metrics.memoryStart, endMB: memoryEnd, peakMB: max(footprints.max() ?? 0, memoryEnd),
                          meanMB: footprints.isEmpty ? memoryEnd : footprints.reduce(0, +) / Double(footprints.count),
                          growthMB: memoryEnd - metrics.memoryStart),
            cpu: .init(meanPercent: cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count), peakPercent: cpu.max() ?? 0),
            thermal: .init(start: metrics.thermalStart, end: ProcessMetrics.thermalState,
                           worst: (samples.map(\.thermal) + [metrics.thermalStart]).max() ?? metrics.thermalStart,
                           secondsByState: thermalSeconds),
            events: events, samples: samples)
    }

    private static func makeTarget(device: MTLDevice, size: PixelSize) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }
}
