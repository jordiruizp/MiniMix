import AVFAudio
import Core

public enum AudioEngineError: Error, Equatable {
    case invalidFormat
    /// El nodo de la fuente ya pertenece a otro `AVAudioEngine`.
    case nodeAttachedToAnotherEngine
    case notInManualRenderingMode
}

/// Eventos del ciclo de vida de `AudioEngine` (ver `AudioEngine.events`).
public enum AudioEngineEvent: Sendable, Equatable {
    /// El sistema cambió la configuración de la salida y paró el motor.
    case configurationChanged
    /// El motor volvió a arrancar tras el cambio.
    case restarted
    /// No se pudo rearrancar; `isRunning` es false. Descripción del error.
    case restartFailed(String)
}

/// `AVAudioEngine` compartido fuera del Mutex de `AudioEngine`.
///
/// `@unchecked Sendable`: solo se usa sin el Mutex en la cola serie de ciclo de vida para
/// `prepare()`/`start()` (operaciones que `AVAudioEngine` serializa internamente); las mutaciones
/// del grafo siguen haciéndose siempre bajo el Mutex.
final class EngineHandle: @unchecked Sendable {
    let engine: AVAudioEngine
    init(_ engine: AVAudioEngine) { self.engine = engine }
}

/// Configuración de `AudioEngine`.
public struct AudioEngineConfiguration: Sendable {
    public enum RenderMode: Sendable, Equatable {
        /// Dispositivo de salida del sistema.
        case realtime
        /// Render manual offline (tests, exportación): sin dispositivo; se avanza con `renderOffline`.
        case offline(sampleRate: Double, maximumFrameCount: AVAudioFrameCount)
    }

    public var renderMode: RenderMode
    /// Duración de las rampas de ganancia (faders, mute, solo, Master, seguir a Programa).
    public var rampDuration: Double
    /// Frecuencia de publicación de `meters` (Hz) mientras el motor está en marcha; 0 = sin publicación automática.
    public var meterRate: Double
    /// Máximo de la compensación de latencia (memoria reservada para la línea de retardo).
    public var maxLatencyCompensation: Double

    public init(renderMode: RenderMode = .realtime, rampDuration: Double = 0.02,
                meterRate: Double = 30, maxLatencyCompensation: Double = 1) {
        self.renderMode = renderMode
        self.rampDuration = rampDuration
        self.meterRate = meterRate
        self.maxLatencyCompensation = maxLatencyCompensation
    }
}

/// Ajustes de un canal; se guardan aunque la entrada aún no esté conectada.
struct ChannelSettings {
    var volume: Float = 1
    var muted = false
    var solo = false
    var followsProgram = true
}

/// Una etapa de ganancia con rampa dentro del grafo.
struct GainStage {
    let node: AVAudioUnitEffect
    let control: RampGainControl
}

/// Nodos de un canal de entrada.
///
/// ```
/// source.node → input (AVAudioMixerNode: conversión al formato canónico)
///             → fader (volumen·mute, vúmetro del canal)
///             ├→ programGate (seguir a Programa / fundido) → masterMixer
///             └→ soloGate (solo-escucha)                     → soloMixer
/// ```
struct Channel {
    let id: InputID
    let source: AVAudioNode
    let ownsSourceNode: Bool
    let input: AVAudioMixerNode
    let fader: GainStage
    let programGate: GainStage
    let soloGate: GainStage

    var nodes: [AVAudioNode] { [input, fader.node, programGate.node, soloGate.node] }
}

/// Canal dado de baja que espera a que termine su rampa a 0 para desmontarse.
struct RetiringChannel {
    let channel: Channel
    /// Offline: muestra renderizada a partir de la cual se desmonta; nil = temporizador (tiempo real).
    let deadlineFrame: Int?
}

/// Ganancias objetivo de las etapas de un canal (diagnóstico y tests).
struct ChannelGains: Equatable {
    var fader: Float
    var program: Float
    var solo: Float
}
