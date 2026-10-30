import AVFAudio
import Core

/// Sincronismo A/V (plan 10.2) y latencia de salida.
extension AudioEngine {
    // MARK: Sincronismo A/V

    /// Adelanto del audio de un `AVPlayer` sacado por `MTAudioProcessingTap` respecto a la
    /// presentación de su vídeo, **sin** contar la latencia del dispositivo (que el reproductor
    /// ya descuenta y la salida del motor vuelve a sumar). Medido con el test de claqueta por la
    /// cadena real (VideoInput → AudioEngine, altavoces integrados, PCM y AAC, 11 pasadas): adelanto
    /// en render 77,6…92,1 ms (media ≈ 84) − latencia HAL 11,3 ms ≈ 72 ms. El adelanto es constante
    /// dentro de una reproducción (±0,1 ms) pero varía ±7 ms entre reproducciones.
    public static let playerTapLead: Double = 0.072

    /// Retardo manual de una entrada (ms), aplicado antes del gate de Programa (así el fundido
    /// de la transición actúa sobre el audio ya alineado con su vídeo). Se suma al retardo del
    /// perfil de sincronismo y admite negativos (p. ej. calibrar a la baja el adelanto de
    /// `.playerTap`); el retardo efectivo se limita a 0…`maxInputDelay`.
    public func setInputDelay(milliseconds: Double, for input: InputID) {
        updateSettings(input) { $0.inputDelay = milliseconds.isFinite ? milliseconds / 1_000 : 0 }
    }

    /// Perfil de sincronismo de una entrada (`.playerTap` para VideoInput): ajuste automático.
    public func setSyncProfile(_ profile: InputSyncProfile, for input: InputID) {
        updateSettings(input) { $0.syncProfile = profile }
    }

    /// Retardo efectivo de una entrada (ms), limitado a `maxInputDelay`.
    public func inputDelayMilliseconds(for input: InputID) -> Double {
        let maxDelay = max(0, configuration.maxInputDelay)
        return state.withLock { min(Self.inputDelay(for: input, in: $0), maxDelay) * 1_000 }
    }

    /// Del tick del `MasterClock` a la pantalla integrada (s). Por defecto 1 fotograma a 60 fps
    /// (el fotograma se compone en el tick y se muestra en el siguiente vsync). Solo retrasa las
    /// entradas `.playerTap` (para alinear su contenido con su vídeo antes del gate); **no** retrasa
    /// el gate de Programa ni las entradas `.direct`.
    ///
    /// - La latencia de una pantalla externa o proyector **no** va aquí: va en la compensación
    ///   global (`setLatencyCompensation(milliseconds:)`), que retrasa toda la salida (contenido y
    ///   fundidos) por igual.
    /// - Limitación con salidas de audio de alta latencia (Bluetooth, AirPlay: 100–250 ms): el
    ///   audio, incluido el fundido del gate, llega tarde respecto a la imagen en esa latencia
    ///   menos la del vídeo; la compensación global solo puede retrasar audio, así que corregirlo
    ///   exigiría retrasar el vídeo (Media/App).
    public var videoPresentationLatency: Double {
        get { state.withLock { $0.videoPresentationLatency } }
        set {
            state.withLock { state in
                state.videoPresentationLatency = newValue.isFinite ? max(0, newValue) : 0
                Self.applyGains(&state)
            }
        }
    }

    // MARK: Latencia de salida

    /// Latencia del dispositivo de salida que usa el motor (HAL). nil en modo offline o si no hay
    /// dispositivo.
    /// No toma el cerrojo del estado: el `deviceID` está en un atómico (actualizado al crear el
    /// motor y en cada cambio de configuración) y las consultas al HAL, que pueden tardar, van
    /// fuera de cualquier cerrojo. Así la sonda de inicios puede llamarlo desde el hilo del tap.
    public var outputLatency: OutputLatency? {
        guard configuration.renderMode == .realtime else { return nil }
        let deviceID = outputDeviceID.load(ordering: .relaxed)
        return OutputLatency.device(deviceID) ?? OutputLatency.defaultOutputDevice()
    }

    /// `AVAudioOutputNode.presentationLatency` (s): render → altavoz según `AVAudioEngine`
    /// (0 en offline o con el motor parado en algunos dispositivos).
    public var outputPresentationLatency: Double {
        state.withLock { $0.engine.isInManualRenderingMode ? 0 : $0.engine.outputNode.presentationLatency }
    }

    /// Retardo efectivo de una entrada (s): manual + perfil de sincronismo.
    static func inputDelay(for id: InputID, in state: State) -> Double {
        let settings = state.settings[id] ?? ChannelSettings()
        let profile: Double = switch settings.syncProfile {
        case .direct: 0
        case .playerTap: playerTapLead + state.videoPresentationLatency
        }
        return max(0, settings.inputDelay + profile)
    }

    static func inputDelayFrames(for id: InputID, in state: State) -> Int {
        Int((inputDelay(for: id, in: state) * state.format.sampleRate).rounded())
    }
}
