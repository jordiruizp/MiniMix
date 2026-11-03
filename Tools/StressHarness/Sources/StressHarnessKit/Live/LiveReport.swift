import Foundation
import TestSupport

/// Informe JSON de un escenario T90 (uno por ejecución en `Tools/reports/`).
public struct LiveReport: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Sample: Codable, Sendable {
        public var t: Double
        public var footprintMB: Double
        public var residentMB: Double
        /// CPU del proceso (100 = un núcleo).
        public var cpuPercent: Double
        /// CPU de toda la máquina (0…100); incluye VTDecoderXPCService y otros procesos.
        public var systemCPUPercent: Double?
        /// Utilización de GPU de todo el sistema (Monitor de Actividad).
        public var gpuSystemPercent: Double?
        /// Tiempo de GPU de nuestros fotogramas / tiempo de pared en el intervalo.
        public var gpuFramePercent: Double
        public var thermal: ThermalLevel
        public var renderedFrames: Int
        /// Perdidos acumulados (reloj + contrapresión).
        public var droppedFrames: Int
        public var activeDecoders: Int
    }

    public struct ColdStart: Codable, Sendable {
        /// Servicios + 8 entradas preparadas.
        public var setupSeconds: Double
        /// Desde el inicio del montaje hasta el primer fotograma de Programa completado con código legible.
        public var firstProgramFrameSeconds: Double?
        /// Desde el arranque del proceso hasta ese fotograma (incluye dyld y la inicialización de Swift).
        public var processLaunchToFirstFrameSeconds: Double?
    }

    public struct Frames: Codable, Sendable {
        public var targetFPS: Double
        public var measuredFPS: Double
        public var expected: Int
        public var rendered: Int
        /// Huecos en los ticks recibidos por el bucle (fotogramas de la rejilla sin tick).
        public var droppedByClock: Int
        /// `MasterClock.stats.skippedTicks` (el reloj llegó tarde y saltó fotogramas).
        public var clockSkippedTicks: Int
        /// Ticks descartados por tener ya 3 fotogramas en vuelo en la GPU.
        public var droppedByBackpressure: Int
        /// `RenderStatsCollector` del compositor de Programa (huecos entre envíos).
        public var compositorDropped: Int
        /// max(huecos del reloj + contrapresión, colector del compositor).
        public var dropped: Int
        /// Perdidos durante el calentamiento (`warmupSeconds`: arranque de decodificadores y cachés).
        public var droppedDuringWarmup: Int
        /// Máximo de perdidos (reloj + contrapresión) en cualquier ventana de 30 min tras el calentamiento.
        public var maxDroppedIn30Minutes: Int
        public var outOfOrderCompletions: Int
        /// Perdidos tras el calentamiento en intervalos de muestreo con la máquina cargada (CPU del sistema
        /// ≥ 70 %: otros procesos) y con la máquina tranquila. La máquina de desarrollo es compartida.
        public var droppedWhileSystemBusy: Int
        public var droppedWhileSystemQuiet: Int
    }

    public struct Usage: Codable, Sendable {
        public var processCPUMeanPercent: Double
        public var processCPUPeakPercent: Double
        /// CPU media del proceso sobre todos los núcleos (0…100).
        public var processCPUMeanOfMachinePercent: Double
        public var systemCPUMeanPercent: Double?
        public var gpuFrameMeanPercent: Double
        public var gpuFramePeakPercent: Double
        public var gpuSystemMeanPercent: Double?
        public var gpuSystemPeakPercent: Double?
    }

    public struct Memory: Codable, Sendable {
        public var startMB, peakMB, endMB: Double
        public var residentPeakMB: Double
        /// Pendiente (regresión lineal tras el calentamiento) de phys_footprint, MB por hora.
        public var footprintDriftMBPerHour: Double
        public var residentDriftMBPerHour: Double
    }

    public struct Thermal: Codable, Sendable {
        public var start, end, worst: ThermalLevel
        public var secondsByState: [String: Double]
        /// Primer instante (s) por encima de `.fair`, si lo hubo.
        public var firstAboveFairAt: Double?
    }

    public struct Cuts: Codable, Sendable {
        public var cuts: Int
        public var fades: Int
        /// Fotogramas entre el tick del comando y el primer fotograma de Programa con la nueva entrada.
        public var latencyFrames: StressReport.Stats
        /// Del comando a la GPU completando ese fotograma (ms).
        public var latencyMs: StressReport.Stats
        public var measured: Int
        public var unmatched: Int
    }

    public struct ProgramFeed: Codable, Sendable {
        public var analyzedFrames: Int
        public var transitionFramesExcluded: Int
        public var black: Int
        public var unreadable: Int
        public var filler: Int
        public var repeats: Int
        public var longestRun: Int
        public var skippedFrames: Int
        public var boundarySkips: Int
        public var backwardJumps: Int
        public var loopWraps: Int
        public var clipChanges: Int
        /// Escenario de playlist: fotogramas con un clip que no es de la playlist.
        public var foreignClipFrames: Int
    }

    public struct PlaylistStats: Codable, Sendable {
        public var items: Int
        public var switches: Int
        public var lateSwitches: Int
        public var maxLoadedItems: Int
        public var createdItems: Int
        public var lastStartLatencyMs: Double?
    }

    public struct Target: Codable, Sendable {
        public var name: String
        public var target: String
        public var measured: String
        /// nil = informativo / no medido.
        public var pass: Bool?
    }

    public var schemaVersion = currentSchemaVersion
    public var scenario: LiveScenarioConfig
    public var startedAt: Date
    public var durationSeconds: Double
    public var machine: MachineInfo
    public var gpu: String
    public var inputs: [LiveRig.Input]
    public var audio: String
    public var coldStart: ColdStart
    public var frames: Frames
    public var deliveryIntervalMs: StressReport.Stats
    public var cpuFrameTimeMs: StressReport.Stats
    public var gpuFrameTimeMs: StressReport.Stats
    public var usage: Usage
    public var memory: Memory
    public var thermal: Thermal
    public var cuts: Cuts
    public var program: ProgramFeed
    public var playlist: PlaylistStats?
    public var maxActiveDecoders: Int
    public var avOffset: String
    public var targets: [Target]
    public var samples: [Sample]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    @discardableResult
    public func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stem = "\(scenario.name)-real-\(formatter.string(from: startedAt))"
        var url = directory.appendingPathComponent("\(stem).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem)-\(suffix).json")
            suffix += 1
        }
        try jsonData().write(to: url, options: .withoutOverwriting)
        return url
    }
}
