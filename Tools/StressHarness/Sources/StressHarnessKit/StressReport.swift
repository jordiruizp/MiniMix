import Foundation
import TestSupport

/// Informe JSON de una ejecución (uno por ejecución en `Tools/reports/`).
public struct StressReport: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Frames: Codable, Sendable {
        public var targetFPS: Double
        public var measuredFPS: Double
        /// Fotogramas de la rejilla del reloj durante la ejecución.
        public var expected: Int
        /// Fotogramas codificados y completados por la GPU (o procesados, sin GPU).
        public var rendered: Int
        /// expected − rendered: huecos del reloj + descartes por contrapresión de la GPU.
        public var dropped: Int
        public var droppedByClock: Int
        public var droppedByBackpressure: Int
    }

    public struct Stats: Codable, Sendable {
        public var mean, p50, p95, p99, max: Double

        public init(_ values: [Double]) {
            let sorted = values.sorted()
            func pct(_ p: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
            }
            mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
            p50 = pct(0.5)
            p95 = pct(0.95)
            p99 = pct(0.99)
            max = sorted.last ?? 0
        }
    }

    public struct Memory: Codable, Sendable {
        public var startMB, endMB, peakMB, meanMB: Double
        /// endMB − startMB: crecimiento (fugas) durante la ejecución.
        public var growthMB: Double
    }

    public struct CPU: Codable, Sendable {
        /// 100 = un núcleo completo.
        public var meanPercent, peakPercent: Double
    }

    public struct Thermal: Codable, Sendable {
        public var start, end, worst: ThermalLevel
        public var secondsByState: [String: Double]
    }

    public struct Events: Codable, Sendable {
        public var switches = 0
        public var transitionsCompleted = 0
        public var playlistItemsStarted = 0
        public var playlistLoops = 0
        /// Máximo de items de playlist cargados a la vez (regla: ≤ 2).
        public var maxLoadedPlaylistItems = 0
        /// Fotogramas en que el item actual de la playlist aún no estaba preparado (negro).
        public var playlistNotReadyFrames = 0
    }

    public var schemaVersion = currentSchemaVersion
    public var scenario: ScenarioConfig
    public var pipeline: String
    /// Implementación usada para cada pieza (reloj, compositor, switcher, secuenciador, fuentes).
    public var components: [String: String]
    public var gpu: String?
    public var startedAt: Date
    public var durationSeconds: Double
    public var machine: MachineInfo
    public var frames: Frames
    /// Intervalo entre ticks del reloj procesados (ms).
    public var tickIntervalMs: Stats
    /// Tiempo de GPU por fotograma (ms).
    public var gpuTimeMs: Stats
    /// Tiempo de CPU del bucle por fotograma (ms).
    public var cpuFrameTimeMs: Stats
    public var memory: Memory
    public var cpu: CPU
    public var thermal: Thermal
    public var events: Events
    public var samples: [ResourceSample]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> StressReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StressReport.self, from: data)
    }

    /// Escribe `<dir>/<escenario>-<fecha>.json` y devuelve la URL.
    @discardableResult
    public func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("\(scenario.name)-\(pipeline)-\(formatter.string(from: startedAt)).json")
        try jsonData().write(to: url, options: .atomic)
        return url
    }
}
