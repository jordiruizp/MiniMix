import Core

/// Escenario de estrés T90 sobre los módulos reales (sección 10.2 del plan): lienzo 1080p60,
/// 8 entradas (5 vídeos, imagen, color, playlist de 50 items), 2 activas (Programa + Preview).
public struct LiveScenarioConfig: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        /// Corte y fundido alternos cada `every` s rotando por las 8 entradas.
        case cuts(every: Double, fadeSeconds: Double)
        /// Playlist de 50 items en Programa todo el tiempo; Preview rota entre los vídeos cada `previewEvery` s.
        case playlist(previewEvery: Double)
    }

    public var name: String
    public var kind: Kind
    public var durationSeconds: Double
    public var canvas: CanvasFormat
    public var sampleIntervalSeconds: Double
    /// Muestras anteriores a esto no cuentan para la deriva de memoria (calentamiento).
    public var warmupSeconds: Double
    /// Cada cuánto se imprime el progreso (ejecuciones largas).
    public var progressIntervalSeconds: Double

    public init(name: String, kind: Kind, durationSeconds: Double,
                canvas: CanvasFormat = CanvasFormat(size: .hd1080, frameRate: .fps60),
                sampleIntervalSeconds: Double = 5, warmupSeconds: Double = 60, progressIntervalSeconds: Double = 60) {
        self.name = name
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.canvas = canvas
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.warmupSeconds = warmupSeconds
        self.progressIntervalSeconds = progressIntervalSeconds
    }

    public static let builtIn: [LiveScenarioConfig] = [
        LiveScenarioConfig(name: "stress-2h-cuts", kind: .cuts(every: 3, fadeSeconds: 1), durationSeconds: 7200,
                           sampleIntervalSeconds: 10),
        LiveScenarioConfig(name: "stress-1h-playlist", kind: .playlist(previewEvery: 30), durationSeconds: 3600,
                           sampleIntervalSeconds: 10),
        LiveScenarioConfig(name: "stress-5m-cuts", kind: .cuts(every: 3, fadeSeconds: 1), durationSeconds: 300,
                           sampleIntervalSeconds: 2, warmupSeconds: 30, progressIntervalSeconds: 30),
        LiveScenarioConfig(name: "stress-5m-playlist", kind: .playlist(previewEvery: 30), durationSeconds: 300,
                           sampleIntervalSeconds: 2, warmupSeconds: 30, progressIntervalSeconds: 30)
    ]

    public static func named(_ name: String) -> LiveScenarioConfig? { builtIn.first { $0.name == name } }
}
