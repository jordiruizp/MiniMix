import Core
import Foundation
import Observation

/// Barra de estado: render (servicio inyectado) + RAM y estado térmico reales del proceso.
@MainActor @Observable
public final class StatusViewModel {
    public private(set) var fps: Double = 0
    public private(set) var droppedFrames = 0
    /// Ocupación de GPU aproximada: tiempo de GPU / duración de fotograma.
    public private(set) var gpuPercent: Double = 0
    public private(set) var memoryBytes: UInt64?
    public private(set) var thermal: ProcessInfo.ThermalState = .nominal

    @ObservationIgnored private let renderStats: @MainActor () -> RenderStats

    init(renderStats: @escaping @MainActor () -> RenderStats) {
        self.renderStats = renderStats
    }

    public func refresh() {
        let stats = renderStats()
        fps = stats.fps
        droppedFrames = stats.droppedFrames
        gpuPercent = stats.fps > 0 ? min(100, stats.gpuTimeMs * stats.fps / 10) : 0
        memoryBytes = ProcessMetrics.memoryFootprint()
        thermal = ProcessMetrics.thermalState
    }

    public var thermalIsWarning: Bool { thermal == .serious || thermal == .critical }
}
