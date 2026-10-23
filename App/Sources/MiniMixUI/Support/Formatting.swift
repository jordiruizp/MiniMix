import Foundation

/// Formatos de la interfaz (tiempos, memoria, dB).
public enum Formatting {
    /// `m:ss` o `h:mm:ss`; valores negativos se tratan como 0.
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Tiempo restante con signo menos, o `--:--` si no se conoce.
    public static func remaining(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        return "-" + clock(seconds)
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
