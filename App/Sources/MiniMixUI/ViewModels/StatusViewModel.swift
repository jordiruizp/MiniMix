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
    /// Decodificadores de vídeo activos / límite (nil sin `InputManager`).
    public private(set) var decoders: DecoderUsage?

    @ObservationIgnored private let renderStats: @MainActor () -> RenderStats
    @ObservationIgnored private let decoderUsage: (@MainActor () -> DecoderUsage)?
    @ObservationIgnored private let thermalState: @MainActor () -> ProcessInfo.ThermalState

    init(renderStats: @escaping @MainActor () -> RenderStats,
         decoderUsage: (@MainActor () -> DecoderUsage)? = nil,
         thermalState: @escaping @MainActor () -> ProcessInfo.ThermalState = { ProcessMetrics.thermalState }) {
        self.renderStats = renderStats
        self.decoderUsage = decoderUsage
        self.thermalState = thermalState
    }

    public func refresh() {
        let stats = renderStats()
        fps = stats.fps
        droppedFrames = stats.droppedFrames
        gpuPercent = stats.fps > 0 ? min(100, stats.gpuTimeMs * stats.fps / 10) : 0
        memoryBytes = ProcessMetrics.memoryFootprint()
        thermal = thermalState()
        decoders = decoderUsage?()
    }

    public var thermalIsWarning: Bool { thermal == .serious || thermal == .critical }
    public var decodersAtLimit: Bool { decoders.map { $0.active >= $0.limit } ?? false }

    /// Avisos visibles de la barra de estado (sección 2.1, Diagnóstico).
    public static func warnings(thermal: ProcessInfo.ThermalState, decoders: DecoderUsage?,
                                experimentalCanvas: Bool) -> [String] {
        var result: [String] = []
        switch thermal {
        case .critical: result.append("Temperatura crítica: el sistema está limitando el rendimiento")
        case .serious: result.append("Temperatura alta: reduce entradas de vídeo o usa 1080p")
        default: break
        }
        if let decoders, decoders.active >= decoders.limit {
            result.append("Decodificadores al límite (\(decoders.active)/\(decoders.limit)): las demás entradas de vídeo se pausan")
        }
        if experimentalCanvas { result.append("Lienzo 4K experimental") }
        return result
    }
}
