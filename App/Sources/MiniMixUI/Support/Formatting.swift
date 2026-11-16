import Foundation

/// Formatos de la interfaz (tiempos, memoria, dB).
public enum Formatting {
    /// `m:ss` o `h:mm:ss`; valores negativos se tratan como 0.
    public static func clock(_ seconds: Double) -> String {
        clockString(Int(max(0, seconds).rounded(.up)))
    }

    /// Tiempo restante con signo menos, o `--:--` si no se conoce.
    public static func remaining(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        return "-" + clock(seconds)
    }

    /// Cuenta atrás con frames restantes (`-m:ss.ff` a los fps dados), o `--:--` si no se
    /// conoce. Convención de timecode: los segundos van hacia abajo y el resto son frames
    /// (`-0:00.12` son 12 frames para el final).
    public static func remaining(_ seconds: Double?, fps: Double) -> String {
        guard let seconds, fps > 0 else { return "--:--" }
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let lastFrame = max(0, Int(fps.rounded(.up)) - 1)
        let frames = min(Int((clamped - Double(whole)) * fps + 1e-6), lastFrame)
        return "-" + clockString(whole) + String(format: ".%02d", frames)
    }

    /// Tiempo transcurrido (redondeo hacia abajo: no marca `0:01` hasta cumplir el segundo),
    /// o `--:--` si no se conoce.
    public static func elapsed(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        return clockString(Int(max(0, seconds)))
    }

    private static func clockString(_ total: Int) -> String {
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    public static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let gib = Double(bytes) / 1_073_741_824
        return gib >= 1 ? String(format: "%.1f GB", gib) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    public static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

    /// Ganancia lineal → dB (−∞ para 0).
    public static func decibels(gain: Float) -> String {
        guard gain > 0.0001 else { return "−∞ dB" }
        let db = 20 * log10(gain)
        return String(format: "%+.1f dB", db)
    }
}
