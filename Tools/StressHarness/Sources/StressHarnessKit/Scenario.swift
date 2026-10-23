import Core

/// Escenario configurable del harness (se puede cargar desde JSON con `--scenario archivo.json`).
public struct ScenarioConfig: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        /// Cambia Programa cada `seconds` rotando entre `inputs` entradas.
        case switchEvery(seconds: Double, transition: TransitionKind, fadeSeconds: Double)
        /// Playlist de `items` elementos de `itemSeconds` cada uno (vídeo/imagen/color alternos).
        case playlist(items: Int, itemSeconds: Double, loop: Bool)
    }

    public var name: String
    public var kind: Kind
    public var durationSeconds: Double
    public var canvas: CanvasFormat
    /// Entradas del switcher (en `playlist`, además de la propia playlist).
    public var inputs: Int
    /// Periodo de muestreo de memoria/CPU/térmica.
    public var sampleIntervalSeconds: Double

    public init(name: String, kind: Kind, durationSeconds: Double, canvas: CanvasFormat = CanvasFormat(),
                inputs: Int = 4, sampleIntervalSeconds: Double = 1) {
        self.name = name
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.canvas = canvas
        self.inputs = inputs
        self.sampleIntervalSeconds = sampleIntervalSeconds
    }

    /// Escenarios predefinidos (backlog 8.5 / sección 10 del plan).
    public static let builtIn: [ScenarioConfig] = [
        ScenarioConfig(name: "switch-every-3s",
                       kind: .switchEvery(seconds: 3, transition: .cut, fadeSeconds: 0), durationSeconds: 30),
        ScenarioConfig(name: "fade-every-3s",
                       kind: .switchEvery(seconds: 3, transition: .fade, fadeSeconds: 1), durationSeconds: 30),
        ScenarioConfig(name: "playlist-50",
                       kind: .playlist(items: 50, itemSeconds: 0.5, loop: true), durationSeconds: 30, inputs: 1)
    ]

    public static func named(_ name: String) -> ScenarioConfig? { builtIn.first { $0.name == name } }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
