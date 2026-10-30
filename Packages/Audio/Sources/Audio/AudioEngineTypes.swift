import AVFAudio
import Core

public enum AudioEngineError: Error, Equatable {
    case invalidFormat
    /// El nodo de la fuente ya pertenece a otro `AVAudioEngine`.
    case nodeAttachedToAnotherEngine
    case notInManualRenderingMode
    /// No se pudo instanciar la unidad de ganancia propia (`OSStatus`, p. ej. -3000).
    case audioUnitUnavailable(OSStatus)
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
    /// Máximo del retardo por entrada (memoria reservada por canal: 2 canales × frecuencia × esto).
    public var maxInputDelay: Double

    public init(renderMode: RenderMode = .realtime, rampDuration: Double = 0.02,
                meterRate: Double = 30, maxLatencyCompensation: Double = 1, maxInputDelay: Double = 0.25) {
        self.renderMode = renderMode
        self.rampDuration = rampDuration
        self.meterRate = meterRate
        self.maxLatencyCompensation = maxLatencyCompensation
        self.maxInputDelay = maxInputDelay
    }
}

/// Ajustes de un canal; se guardan aunque la entrada aún no esté conectada.
struct ChannelSettings {
    var volume: Float = 1
    var muted = false
    var solo = false
    var followsProgram = true
    /// Retardo manual de la entrada (s), antes del gate de Programa; puede ser negativo (se suma
    /// al del perfil y el total se limita a ≥ 0).
    var inputDelay: Double = 0
    var syncProfile: InputSyncProfile = .direct
}

/// Cómo llega el audio de una entrada respecto a su vídeo (sincronismo A/V, plan 10.2).
public enum InputSyncProfile: Sendable, Equatable {
    /// Audio sin vídeo asociado o ya alineado (AudioInput, AVAudioPlayerNode): sin retardo extra.
    case direct
    /// Audio de un `AVPlayer` sacado con `MTAudioProcessingTap` (VideoInput). Se retrasa
    /// `AudioEngine.playerTapLead + videoPresentationLatency`; con el tap alineado por tiempo de
    /// item de Media `playerTapLead` es 0, así que equivale a `videoPresentationLatency` (el
    /// fotograma se ve un vsync después del tick en que su audio ya está alineado).
    case playerTap
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
    /// Variable: un canal en baja puede recuperarse bajo otro id (re-attach del mismo nodo).
    var id: InputID
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
