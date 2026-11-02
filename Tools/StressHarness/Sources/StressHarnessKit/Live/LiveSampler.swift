import Foundation
import Media
import TestSupport

/// Muestreo periódico (tarea propia, fuera del bucle de render) de memoria, CPU, GPU, térmica,
/// fotogramas y decodificadores activos.
final class LiveSampler: Sendable {
    private let interval: Double
    private let renderer: LiveFrameRenderer
    private let manager: InputManager
    private let collected = LockedBox<[LiveReport.Sample]>([])
    private let task = LockedBox<Task<Void, Never>?>(nil)
    /// Perdidos acumulados por el bucle (los publica el runner).
    let dropped = LockedBox(0)

    init(interval: Double, renderer: LiveFrameRenderer, manager: InputManager) {
        self.interval = interval
        self.renderer = renderer
        self.manager = manager
    }

    func start() {
        let interval = interval
        let renderer = renderer
        let manager = manager
        let collected = collected
        let dropped = dropped
        let newTask = Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            var cpu = CPUUsageMeter()
            var system = SystemCPUMeter()
            _ = system.sample()
            var lastGPU = 0.0
            var lastWall = start
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
                let now = ContinuousClock.now
                let probe = renderer.probe.withLock { ($0.gpuSeconds, $0.completed) }
                let wall = lastWall.duration(to: now).seconds
                let mb = 1.0 / 1_048_576
                let sample = LiveReport.Sample(
                    t: start.duration(to: now).seconds,
                    footprintMB: Double(ProcessMetrics.physFootprint() ?? 0) * mb,
                    residentMB: Double(ProcessMetrics.residentSize() ?? 0) * mb,
                    cpuPercent: cpu.sample(), systemCPUPercent: system.sample(),
                    gpuSystemPercent: GPUUtilization.systemPercent(),
                    gpuFramePercent: wall > 0 ? (probe.0 - lastGPU) / wall * 100 : 0,
                    thermal: ProcessMetrics.thermalState, renderedFrames: probe.1,
                    droppedFrames: dropped.withLock { $0 }, activeDecoders: manager.activeDecoderIDs.count)
                lastGPU = probe.0
                lastWall = now
                collected.withLock { $0.append(sample) }
            }
        }
        task.withLock { $0 = newTask }
    }

    func stop() {
        task.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    var samples: [LiveReport.Sample] { collected.withLock { $0 } }
}
