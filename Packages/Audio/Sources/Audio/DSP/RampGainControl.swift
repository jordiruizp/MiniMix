import Foundation
import Synchronization

/// Estado compartido entre el hilo de control y el hilo de audio de una etapa `RampGainUnit`.
///
/// Solo contiene atómicos (sin cerrojos): el hilo de audio nunca espera. Los `Float` se guardan
/// como patrón de bits en `UInt32`. Para valores ≥ 0 el orden de los patrones de bits coincide con
/// el orden numérico, así que el pico se acumula con `Atomic.max` sin bucles CAS.
final class RampGainControl: Sendable {
    /// Número de canales de audio con medidor (el formato canónico del motor es estéreo).
    static let meteredChannels = 2

    private let targetBits: Atomic<UInt32>
    private let appliedBits: Atomic<UInt32>
    private let peakLeft = Atomic<UInt32>(0)
    private let peakRight = Atomic<UInt32>(0)
    private let delayFramesValue = Atomic<Int>(0)

    init(gain: Float = 1) {
        targetBits = Atomic(gain.bitPattern)
        appliedBits = Atomic(gain.bitPattern)
    }

    /// Ganancia lineal objetivo; el hilo de audio rampa hacia ella.
    var target: Float {
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(max(0, newValue).bitPattern, ordering: .relaxed) }
    }

    /// Ganancia efectivamente aplicada al final del último bloque renderizado.
    var applied: Float { Float(bitPattern: appliedBits.load(ordering: .relaxed)) }

    func storeApplied(_ gain: Float) { appliedBits.store(gain.bitPattern, ordering: .relaxed) }

    /// Retardo deseado en muestras (solo para etapas con línea de retardo).
    var delayFrames: Int {
        get { delayFramesValue.load(ordering: .relaxed) }
        set { delayFramesValue.store(max(0, newValue), ordering: .relaxed) }
    }

    /// Hilo de audio: acumula el pico lineal (≥ 0) de un bloque.
    func recordPeak(_ peak: Float, channel: Int) {
        let bits = peak.isFinite ? max(0, peak).bitPattern : Float(0).bitPattern
        switch channel {
        case 0: _ = peakLeft.max(bits, ordering: .relaxed)
        case 1: _ = peakRight.max(bits, ordering: .relaxed)
        default: break
        }
    }

    /// Hilo de medidores: devuelve los picos lineales desde la última lectura y los pone a cero.
    func takePeaks() -> [Float] {
        [Float(bitPattern: peakLeft.exchange(0, ordering: .relaxed)),
         Float(bitPattern: peakRight.exchange(0, ordering: .relaxed))]
    }
}

/// Conversión lineal → dBFS para los vúmetros.
public enum Decibels {
    /// Valor que se publica para silencio digital.
    public static let silenceFloor: Float = -160

    public static func fromLinear(_ value: Float) -> Float {
        guard value > 0, value.isFinite else { return silenceFloor }
        return max(silenceFloor, 20 * log10(value))
    }
}
