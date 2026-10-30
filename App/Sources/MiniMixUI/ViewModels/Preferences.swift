import Core
import Foundation

/// Preferencias de la app (escena Settings, T91). Se guardan en `UserDefaults`.
public struct Preferences: Equatable, Sendable {
    public enum CanvasPreset: String, CaseIterable, Sendable, Identifiable {
        case hd720, hd1080, uhd4K
        public var id: String { rawValue }
        public var size: PixelSize {
            switch self {
            case .hd720: .hd720
            case .hd1080: .hd1080
            case .uhd4K: .uhd4K
            }
        }
        public var label: String {
            switch self {
            case .hd720: "720p (1280×720)"
            case .hd1080: "1080p (1920×1080)"
            case .uhd4K: "4K (3840×2160) · experimental"
            }
        }
        public init?(size: PixelSize) {
            guard let preset = Self.allCases.first(where: { $0.size == size }) else { return nil }
            self = preset
        }
    }

    /// Frecuencias ofrecidas.
    public static let frameRates: [FrameRate] = [.fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60]

    public var canvasPreset: CanvasPreset = .hd1080
    public var frameRate: FrameRate = .fps60
    /// Fundido del switcher para proyectos nuevos (0,1…5 s).
    public var defaultFadeDuration: Double = 1
    /// Compensación de latencia de la salida de audio (ms, `AudioEngine.setLatencyCompensation`).
    public var latencyCompensationMs: Double = 0
    /// Eficiencia: el monitor de Preview se compone a la mitad de fotogramas (Programa y la salida
    /// siguen a la frecuencia del proyecto).
    public var efficiencyMode = false
    /// Desactivar App Nap (y el reposo de pantalla) mientras la salida de Programa está en el aire.
    public var preventAppNapWhileLive = true

    public init() {}

    public var canvas: CanvasFormat { CanvasFormat(size: canvasPreset.size, frameRate: frameRate) }

    public static func label(for rate: FrameRate) -> String {
        rate.denominator == 1 ? "\(rate.numerator) fps" : String(format: "%.2f fps", rate.fps)
    }

    // MARK: UserDefaults

    enum Key {
        static let canvas = "MiniMix.prefs.canvas"
        static let frameRate = "MiniMix.prefs.frameRate"
        static let fade = "MiniMix.prefs.defaultFade"
        static let latency = "MiniMix.prefs.latencyMs"
        static let efficiency = "MiniMix.prefs.efficiency"
        static let appNap = "MiniMix.prefs.preventAppNap"
    }

    public static func load(from defaults: UserDefaults) -> Preferences {
        var prefs = Preferences()
        if let raw = defaults.string(forKey: Key.canvas), let preset = CanvasPreset(rawValue: raw) {
            prefs.canvasPreset = preset
        }
        if let raw = defaults.string(forKey: Key.frameRate), let rate = Self.parseRate(raw) { prefs.frameRate = rate }
        if defaults.object(forKey: Key.fade) != nil {
            prefs.defaultFadeDuration = Self.clamp(defaults.double(forKey: Key.fade), ModelLimits.switcherFade)
        }
        if defaults.object(forKey: Key.latency) != nil {
            prefs.latencyCompensationMs = Self.clamp(defaults.double(forKey: Key.latency), Self.latencyRange)
        }
        prefs.efficiencyMode = defaults.bool(forKey: Key.efficiency)
        if defaults.object(forKey: Key.appNap) != nil { prefs.preventAppNapWhileLive = defaults.bool(forKey: Key.appNap) }
        return prefs
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(canvasPreset.rawValue, forKey: Key.canvas)
        defaults.set("\(frameRate.numerator)/\(frameRate.denominator)", forKey: Key.frameRate)
        defaults.set(defaultFadeDuration, forKey: Key.fade)
        defaults.set(latencyCompensationMs, forKey: Key.latency)
        defaults.set(efficiencyMode, forKey: Key.efficiency)
        defaults.set(preventAppNapWhileLive, forKey: Key.appNap)
    }

    /// Rango de la compensación de latencia ofrecida en la interfaz.
    public static let latencyRange: ClosedRange<Double> = 0...500

    static func parseRate(_ raw: String) -> FrameRate? {
        let parts = raw.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return FrameRate(parts[0], parts[1])
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
