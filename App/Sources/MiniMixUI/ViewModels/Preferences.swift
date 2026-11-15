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
    /// UID del dispositivo de salida de audio elegido (`AudioOutputDevice.uid`); nil = la salida
    /// predeterminada del sistema (p. ej. el HDMI activo).
    public var audioOutputDeviceUID: String?
    /// Nombre del dispositivo elegido cuando se guardó (para mostrarlo si ya no está conectado).
    public var audioOutputDeviceName: String?
    /// Eficiencia: el monitor de Preview se compone a la mitad de fotogramas (Programa y la salida
    /// siguen a la frecuencia del proyecto).
    public var efficiencyMode = false
    /// Desactivar App Nap (y el reposo de pantalla) mientras la salida de Programa está en el aire.
    public var preventAppNapWhileLive = true
    /// Reproducir automáticamente un vídeo en pausa al pasar a Programa (corte o inicio de
    /// transición) y pausarlo al salir (corte o transición completada). Una playlist arranca
    /// también si su item en curso (o en cola) es un vídeo; al terminar el item manda su
    /// secuenciador, como siempre, y no se pausa al salir de Programa.
    public var autoPlayVideoOnProgram = true

    public init() {}

    public var canvas: CanvasFormat { CanvasFormat(size: canvasPreset.size, frameRate: frameRate) }

    /// Proyecto vacío con los valores por defecto (proyecto inicial y ⌘N).
    public var newProject: Project { Project(canvas: canvas, defaultFadeDuration: defaultFadeDuration) }

    public static func label(for rate: FrameRate) -> String {
        rate.denominator == 1 ? "\(rate.numerator) fps" : String(format: "%.2f fps", rate.fps)
    }

    // MARK: UserDefaults

    enum Key {
        static let canvas = "MiniMix.prefs.canvas"
        static let frameRate = "MiniMix.prefs.frameRate"
        static let fade = "MiniMix.prefs.defaultFade"
        static let latency = "MiniMix.prefs.latencyMs"
        static let audioOutputUID = "MiniMix.prefs.audioOutputUID"
        static let audioOutputName = "MiniMix.prefs.audioOutputName"
        static let efficiency = "MiniMix.prefs.efficiency"
        static let appNap = "MiniMix.prefs.preventAppNap"
        static let autoPlay = "MiniMix.prefs.autoPlayOnProgram"
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
        prefs.audioOutputDeviceUID = defaults.string(forKey: Key.audioOutputUID)
        prefs.audioOutputDeviceName = defaults.string(forKey: Key.audioOutputName)
        prefs.efficiencyMode = defaults.bool(forKey: Key.efficiency)
        if defaults.object(forKey: Key.appNap) != nil { prefs.preventAppNapWhileLive = defaults.bool(forKey: Key.appNap) }
        if defaults.object(forKey: Key.autoPlay) != nil {
            prefs.autoPlayVideoOnProgram = defaults.bool(forKey: Key.autoPlay)
        }
        return prefs
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(canvasPreset.rawValue, forKey: Key.canvas)
        defaults.set("\(frameRate.numerator)/\(frameRate.denominator)", forKey: Key.frameRate)
        defaults.set(defaultFadeDuration, forKey: Key.fade)
        defaults.set(latencyCompensationMs, forKey: Key.latency)
        if let uid = audioOutputDeviceUID {
            defaults.set(uid, forKey: Key.audioOutputUID)
            defaults.set(audioOutputDeviceName, forKey: Key.audioOutputName)
        } else {
            defaults.removeObject(forKey: Key.audioOutputUID)
            defaults.removeObject(forKey: Key.audioOutputName)
        }
        defaults.set(efficiencyMode, forKey: Key.efficiency)
        defaults.set(preventAppNapWhileLive, forKey: Key.appNap)
        defaults.set(autoPlayVideoOnProgram, forKey: Key.autoPlay)
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
