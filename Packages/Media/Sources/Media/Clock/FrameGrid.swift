import CoreMedia
import Core
import Foundation

/// Tiempo del host en nanosegundos (misma base que `CMClockGetHostTimeClock`,
/// `mach_absolute_time`, `CACurrentMediaTime` y `DispatchTime.uptimeNanoseconds`).
enum HostClock {
    static let nanosPerSecond: Int64 = 1_000_000_000

    static func nowNanos() -> Int64 {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        return CMTimeConvertScale(time, timescale: Int32(nanosPerSecond), method: .roundTowardNegativeInfinity).value
    }

    static func hostTime(nanos: Int64) -> HostTime {
        // Separar segundos y resto evita perder precisión con uptimes grandes.
        let secs = nanos / nanosPerSecond
        let rem = nanos % nanosPerSecond
        return HostTime(seconds: Double(secs) + Double(rem) / Double(nanosPerSecond))
    }

    static func nanos(_ time: HostTime) -> Int64 {
        Int64((time.seconds * Double(nanosPerSecond)).rounded())
    }
}

/// Rejilla de fotogramas racional anclada en un instante del host.
///
/// El fotograma `n` empieza en `anchor + ceil(n · den · 1e9 / num)` ns. Todo el
/// cálculo es entero (`Int128`), así que no se acumula error: el fotograma
/// 10⁷ está exactamente donde dice la aritmética racional (± 1 ns de redondeo).
struct FrameGrid: Sendable, Equatable {
    let rate: FrameRate
    let anchorNanos: Int64

    init(rate: FrameRate, anchorNanos: Int64) {
        precondition(rate.numerator > 0 && rate.denominator > 0, "FrameRate inválido: \(rate)")
        self.rate = rate
        self.anchorNanos = anchorNanos
    }

    private var num: Int128 { Int128(rate.numerator) }
    private var denNanos: Int128 { Int128(rate.denominator) * Int128(HostClock.nanosPerSecond) }

    /// Índice del fotograma que contiene `nanos` (floor). Negativo antes del ancla.
    func index(atNanos nanos: Int64) -> Int64 {
        let delta = Int128(nanos) - Int128(anchorNanos)
        let product = delta * num
        var quotient = product / denNanos
        if product % denNanos != 0, product < 0 { quotient -= 1 }
        return Int64(quotient)
    }

    /// Inicio exacto (redondeado hacia arriba al ns) del fotograma `n`.
    func startNanos(ofIndex n: Int64) -> Int64 {
        let product = Int128(n) * denNanos
        var offset = product / num
        if product % num != 0, product > 0 { offset += 1 }
        return anchorNanos + Int64(offset)
    }

    /// Duración nominal de un fotograma en ns (redondeada hacia abajo).
    var frameNanos: Int64 { Int64(denNanos / num) }
}
