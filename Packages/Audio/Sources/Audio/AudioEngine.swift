import AVFAudio
import Core
import os

/// Mezclador de audio de MiniMix sobre `AVAudioEngine` (T40/T41).
///
/// Grafo:
/// ```
/// canal i: source.node → input → fader ─┬→ programGate ─→ masterMixer → masterFader ─→ programListen ─┐
///                                        └→ soloGate ────→ soloMixer ──────────────────→ soloListen ──┴→ listenMixer
/// listenMixer → output (compensación de latencia) → mainMixerNode → salida
/// ```
/// Todas las ganancias (`fader`, gates, Master, escucha) son `RampGainUnit`: rampa lineal por
/// muestra de `rampDuration` (20 ms por defecto) → sin clics.
///
/// Ganancia de un canal hacia Master = `volume` (0…2) · (muted ? 0 : 1) · gate de Programa, donde el
/// gate es 1 si `audioFollowsProgram == false` y, si es true, la ganancia de
/// `TransitionCurve.audioGains` según `transition(from:to:progress:)` (0 si no está en Programa).
///
/// **Solo = solo-escucha (semántica elegida)**: no cambia la mezcla de Programa ni el vúmetro de
/// Master. Mientras haya algún canal en solo, lo que se *escucha* por la salida es la suma de los
/// canales en solo (post-fader y post-mute, pero sin el gate de Programa: sirve para preescuchar una
/// entrada en Preview); sin ningún solo se escucha Master. Hoy solo hay una salida física, así que
/// solo-escucha sustituye a Master en ella (cuando exista una salida de Programa separada, p. ej.
/// grabación o streaming, seguirá recibiendo Master).
///
/// Vúmetros (`meters`, ~30 Hz): pico dBFS por canal de audio [L, R] de cada entrada (post-fader,
/// pre-gate) y de Master (`nil`, post-Master). Silencio = `Decibels.silenceFloor`. `meters` y
/// `events` admiten **un único consumidor** cada uno.
///
/// Concurrencia: el `AVAudioEngine` y los nodos (no `Sendable`) solo se tocan bajo `state` (`LockedState`);
/// el hilo de audio solo lee/escribe atómicos (`RampGainControl`). Todos los métodos son seguros
/// desde cualquier hilo y no bloquean el hilo de audio.
public final class AudioEngine: AudioMixing, Sendable {
    struct State {
        let engine: AVAudioEngine
        let format: AVAudioFormat
        let masterMixer = AVAudioMixerNode()
        let soloMixer = AVAudioMixerNode()
        let listenMixer = AVAudioMixerNode()
        let masterFader: GainStage
        let programListen: GainStage
        let soloListen: GainStage
        let output: GainStage
        var channels: [InputID: Channel] = [:]
        var settings: [InputID: ChannelSettings] = [:]
        var masterVolume: Float = 1
        var program = ProgramFollow.empty
        var latencyCompensation: Double = 0
        /// `start()` llamado y sin `stop()`: tras un cambio de configuración se rearranca.
        var wantsRunning = false
        var configurationObserver: (any NSObjectProtocol)?
        /// Canales dados de baja que aún bajan con rampa antes de desmontarse.
        var retiring: [Int: RetiringChannel] = [:]
        var nextRetiringKey = 0
        /// Muestras renderizadas en modo offline (reloj de las bajas diferidas).
        var renderedFrames = 0
        /// Tests: en offline, usar también la ruta de tiempo real (temporizador) para las bajas.
        var wallClockRetirement = false
        /// Detector de inicios instalado como tap en la etapa de salida (diagnóstico A/V).
        var onsetDetector: OnsetDetector?
    }

    /// Margen tras la rampa antes de desmontar un canal (cubre el búfer de E/S en tiempo real).
    static let retireMargin: Double = 0.05
    /// Tiempo real: si al vencer el plazo la ganancia aplicada aún no es 0 (búferes de E/S grandes,
    /// Bluetooth…), se reintenta cada `retireRetryInterval` hasta `retireMaxAttempts` veces (~2 s).
    static let retireRetryInterval: Double = 0.05
    static let retireMaxAttempts = 40

    public let configuration: AudioEngineConfiguration
    private let state: LockedState<State>
    private let meterPublisher: MeterPublisher
    /// Cola serie de rearranques (no se bloquea a quien recibe la notificación).
    private let lifecycleQueue = DispatchQueue(label: "minimix.audio.lifecycle", qos: .userInitiated)
    private let eventContinuation: AsyncStream<AudioEngineEvent>.Continuation
    private static let logger = Logger(subsystem: "MiniMix", category: "AudioEngine")

    /// Vúmetros (~30 Hz). **Un único consumidor**: es un único `AsyncStream` con
    /// `bufferingNewest(1)` (no hace difusión); iterarlo desde dos tareas a la vez es un error de
    /// programación y cada mensaje lo recibe solo una. Si varias vistas necesitan los niveles, un
    /// solo observador (p. ej. el ViewModel de la mesa de audio) los lee y los reparte.
    public var meters: AsyncStream<[InputID?: [Float]]> { meterPublisher.stream }

    /// Eventos del ciclo de vida (cambio de dispositivo, rearranque, error). **Un único consumidor.**
    public let events: AsyncStream<AudioEngineEvent>

    public init(configuration: AudioEngineConfiguration = AudioEngineConfiguration()) throws {
        self.configuration = configuration
        meterPublisher = MeterPublisher(rate: configuration.meterRate)
        let ramp = configuration.rampDuration

        let engine = AVAudioEngine()
        let sampleRate: Double
        switch configuration.renderMode {
        case .realtime:
            let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            sampleRate = deviceRate > 0 ? deviceRate : 48_000
        case let .offline(rate, maxFrames):
            sampleRate = rate
            guard let manualFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
                throw AudioEngineError.invalidFormat
            }
            try engine.enableManualRenderingMode(.offline, format: manualFormat, maximumFrameCount: maxFrames)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw AudioEngineError.invalidFormat
        }

        var initial = State(
            engine: engine,
            format: format,
            masterFader: try Self.makeStage(gain: 1, ramp: ramp, metering: true),
            programListen: try Self.makeStage(gain: 1, ramp: ramp),
            soloListen: try Self.makeStage(gain: 0, ramp: ramp),
            output: try Self.makeStage(gain: 1, ramp: ramp,
                                   maxDelay: max(0, configuration.maxLatencyCompensation))
        )
        Self.buildBusGraph(&initial)
        meterPublisher.register(initial.masterFader.control, for: nil)
        state = LockedState(initial)
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))

        if configuration.renderMode == .realtime {
            state.withLock { state in
                state.configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: state.engine, queue: nil
                ) { [weak self] _ in self?.handleConfigurationChange() }
            }
        }
    }

    deinit {
        eventContinuation.finish()
        meterPublisher.stop()
        state.withLock { state in
            if let observer = state.configurationObserver { NotificationCenter.default.removeObserver(observer) }
            state.engine.stop()
        }
    }

    // MARK: Ciclo de vida

    /// Arranca el motor (y, en tiempo real, la salida de audio) y la publicación de vúmetros.
    /// **Bloquea** mientras `AVAudioEngine` arranca el dispositivo (puede tardar decenas de ms) y
    /// retiene el cerrojo del estado durante ese tiempo: las demás llamadas esperan; el hilo de
    /// audio no. Preferible llamarlo fuera del hilo principal.
    public func start() throws {
        try state.withLock { state in
            state.engine.prepare()
            try state.engine.start()
            state.wantsRunning = true
        }
        meterPublisher.start()
    }

    public func stop() {
        meterPublisher.stop()
        state.withLock { state in
            state.wantsRunning = false
            state.engine.stop()
            for entry in state.retiring.values { Self.teardown(entry.channel, in: state.engine) }
            state.retiring.removeAll()
        }
    }

    /// Cambio de configuración de la salida (p. ej. se conecta una pantalla HDMI con audio): el
    /// sistema para el motor. El rearranque se encola en `lifecycleQueue` (no bloquea a quien
    /// envía la notificación) y allí se hace **entero bajo `state`**: `AVAudioEngine` no garantiza
    /// seguridad entre hilos, así que reconectar, `prepare()` y `start()` se serializan con
    /// `attach`/`detach`/`start`/`stop`. `engine.start()` bloquea mientras arranca (puede tardar
    /// decenas de ms); durante ese tiempo las demás llamadas esperan al cerrojo, nunca el hilo de
    /// audio. El resultado se registra con `os.Logger` y se publica en `events`.
    func handleConfigurationChange() {
        eventContinuation.yield(.configurationChanged)
        lifecycleQueue.async { [weak self] in self?.restartAfterConfigurationChange() }
    }

    private enum RestartOutcome: Sendable {
        case notNeeded
        case restarted
        case failed(String)
    }

    private func restartAfterConfigurationChange() {
        let outcome = state.withLock { state -> RestartOutcome in
            guard state.wantsRunning, !state.engine.isRunning else { return .notNeeded }
            if !state.engine.isInManualRenderingMode { Self.reconnectOutput(state.engine) }
            state.engine.prepare()
            do {
                try state.engine.start()
                return .restarted
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        switch outcome {
        case .notNeeded:
            break
        case .restarted:
            Self.logger.info("Motor de audio rearrancado tras cambio de configuración")
            eventContinuation.yield(.restarted)
        case .failed(let message):
            Self.logger.error("No se pudo rearrancar el motor de audio: \(message, privacy: .public)")
            eventContinuation.yield(.restartFailed(message))
        }
    }

    /// Espera a que la cola de ciclo de vida termine lo encolado (tests).
    func drainLifecycleQueue() { lifecycleQueue.sync {} }

    /// El grafo interno conserva el formato canónico fijado en `init` (frecuencia de la salida en
    /// ese momento). Si el dispositivo nuevo tiene otra frecuencia o canales, `mainMixerNode → output`
    /// se reconecta con el formato actual del hardware y es `mainMixerNode` quien convierte
    /// (SRC + canales) en ese único punto.
    private static func reconnectOutput(_ engine: AVAudioEngine) {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: min(hardware.channelCount, 2)) else { return }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
    }

    /// Para el motor por debajo, como haría el sistema en un cambio de dispositivo (tests).
    func simulateSystemStop() { state.withLock { $0.engine.stop() } }

    public var isRunning: Bool { state.withLock { $0.engine.isRunning } }

    /// Formato canónico del grafo: estéreo Float32 no entrelazado a la frecuencia de la salida.
    /// Las fuentes se conectan con este formato (ver `attach`).
    public var format: AVAudioFormat {
        // Excepción documentada de `LockedState`: `AVAudioFormat` es inmutable tras crearse
        // (no es `Sendable` en todos los SDK que compila el CI).
        state.withLockUnchecked { $0.format }
    }

    /// Solo en modo `.offline`: renderiza `frameCount` muestras de la salida en `buffer`.
    public func renderOffline(_ frameCount: AVAudioFrameCount,
                              to buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try state.withLock { state in
            guard state.engine.isInManualRenderingMode else { throw AudioEngineError.notInManualRenderingMode }
            let status = try state.engine.renderOffline(frameCount, to: buffer)
            state.renderedFrames += Int(buffer.frameLength)
            let now = state.renderedFrames
            for (key, entry) in state.retiring where (entry.deadlineFrame ?? .max) <= now {
                state.retiring[key] = nil
                Self.teardown(entry.channel, in: state.engine)
            }
            return status
        }
    }

    // MARK: Canales

    /// Conecta la fuente a un canal nuevo (o reemplaza el existente con el mismo id).
    /// Si `source.node` es nil no hay nada que conectar. Si el nodo no está en ningún motor,
    /// el `AudioEngine` lo adjunta (y lo separa en `detach`) y lo conecta con `format`; los
    /// búferes que se programen en un `AVAudioPlayerNode` deben estar en ese formato
    /// (los archivos se convierten solos).
    public func attach(_ source: AudioSource) throws {
        guard let sourceNode = source.node else { return }
        let id = source.id
        let ramp = configuration.rampDuration
        try state.withLock { state in
            if let owner = sourceNode.engine, owner !== state.engine {
                throw AudioEngineError.nodeAttachedToAnotherEngine
            }
            if let previous = state.channels[id] {
                if previous.source === sourceNode {
                    // Misma fuente: nada que reconectar.
                    meterPublisher.register(previous.fader.control, for: id)
                    return
                }
                state.channels[id] = nil
                retire(previous, in: &state)
            }
            // Re-attach de un nodo que aún se está dando de baja (con el mismo id o con otro): se
            // reutilizan sus nodos y la rampa vuelve a subir desde donde esté, con los ajustes del
            // id nuevo (sin desconectar a mitad de rampa → sin clic).
            for (key, entry) in state.retiring where entry.channel.source === sourceNode {
                state.retiring[key] = nil
                var channel = entry.channel
                channel.id = id
                if state.settings[id] == nil { state.settings[id] = ChannelSettings() }
                state.channels[id] = channel
                Self.applyGains(&state)
                meterPublisher.register(channel.fader.control, for: id)
                return
            }
            let channel = Channel(
                id: id,
                source: sourceNode,
                ownsSourceNode: sourceNode.engine == nil,
                input: AVAudioMixerNode(),
                // El fader nace a 0 y sube con rampa si el motor ya está sonando.
                fader: try Self.makeStage(gain: 0, ramp: ramp, metering: true),
                programGate: try Self.makeStage(gain: 0, ramp: ramp),
                soloGate: try Self.makeStage(gain: 0, ramp: ramp)
            )
            if state.settings[id] == nil { state.settings[id] = ChannelSettings() }
            Self.connect(channel, in: &state)
            state.channels[id] = channel
            Self.applyGains(&state)
            meterPublisher.register(channel.fader.control, for: id)
        }
    }

    /// Da de baja el canal. Los ajustes (volumen, mute…) se conservan.
    ///
    /// Sin clic: el canal baja a 0 con rampa y los nodos se desconectan después de
    /// `rampDuration + retireMargin` (en tiempo real con un temporizador; en offline al
    /// renderizar esas muestras; con el motor parado, en el acto). `attachedInputs` ya no lo
    /// incluye desde la llamada.
    public func detach(_ id: InputID) {
        state.withLock { state in
            meterPublisher.unregister(id)
            guard let channel = state.channels.removeValue(forKey: id) else { return }
            retire(channel, in: &state)
            Self.applyGains(&state)
        }
    }

    /// Canales pendientes de desmontar (tests).
    var retiringCount: Int { state.withLock { $0.retiring.count } }

    public var attachedInputs: Set<InputID> { state.withLock { Set($0.channels.keys) } }

    // MARK: AudioMixing

    public func setVolume(_ volume: Float, for input: InputID) {
        updateSettings(input) { $0.volume = Self.clampGain(volume) }
    }

    public func setMute(_ muted: Bool, for input: InputID) {
        updateSettings(input) { $0.muted = muted }
    }

    public func setSolo(_ solo: Bool, for input: InputID) {
        updateSettings(input) { $0.solo = solo }
    }

    public func setAudioFollowsProgram(_ follows: Bool, for input: InputID) {
        updateSettings(input) { $0.followsProgram = follows }
    }

    public func setMasterVolume(_ volume: Float) {
        state.withLock { state in
            state.masterVolume = Self.clampGain(volume)
            Self.applyGains(&state)
        }
    }

    /// Fundido de audio de una transición (T41). Llamar en cada tick con el progreso de la
    /// transición (0 = todo `from`, 1 = todo `to`). Un corte es `progress: 1`.
    public func transition(from: InputID?, to: InputID?, progress: Double) {
        state.withLock { state in
            state.program = ProgramFollow(from: from, to: to, progress: progress)
            Self.applyGains(&state)
        }
    }

    /// Fija la entrada en Programa sin transición (equivale a `transition(from: nil, to: id, progress: 1)`).
    public func setProgram(_ id: InputID?) {
        transition(from: nil, to: id, progress: 1)
    }

    // MARK: Latencia

    /// Compensación de latencia de la salida en milisegundos (riesgo 11: salida externa con
    /// retardo de vídeo). Retrasa todo lo que se escucha; 0…`maxLatencyCompensation`. El cambio
    /// se hace con un fundido corto (10 ms) para evitar clics.
    public var latencyCompensationMilliseconds: Double {
        get { state.withLock { $0.latencyCompensation * 1_000 } }
        set { setLatencyCompensation(milliseconds: newValue) }
    }

    public func setLatencyCompensation(milliseconds: Double) {
        let maxSeconds = max(0, configuration.maxLatencyCompensation)
        state.withLock { state in
            let seconds = min(max(milliseconds.isFinite ? milliseconds / 1_000 : 0, 0), maxSeconds)
            state.latencyCompensation = seconds
            state.output.control.delayFrames = Int((seconds * state.format.sampleRate).rounded())
        }
    }

    /// Sustituye el tap de diagnóstico de la etapa de salida. `make` recibe el nodo y su formato,
    /// instala el tap y devuelve el detector; nil solo quita el actual.
    func installOutputTap(_ make: ((AVAudioNode, AVAudioFormat) -> OnsetDetector)?) {
        state.withLock { state in
            if let previous = state.onsetDetector {
                state.output.node.removeTap(onBus: 0)
                previous.finish()
                state.onsetDetector = nil
            }
            if let make { state.onsetDetector = make(state.output.node, state.format) }
        }
    }

    // MARK: Latencia de salida

    /// Latencia del dispositivo de salida que usa el motor (HAL). nil en modo offline o si no hay
    /// dispositivo.
    public var outputLatency: OutputLatency? {
        state.withLock { state -> OutputLatency? in
            guard !state.engine.isInManualRenderingMode else { return nil }
            let deviceID = state.engine.outputNode.auAudioUnit.deviceID
            return OutputLatency.device(deviceID) ?? OutputLatency.defaultOutputDevice()
        }
    }

    /// `AVAudioOutputNode.presentationLatency` (s): render → altavoz según `AVAudioEngine`
    /// (0 en offline o con el motor parado en algunos dispositivos).
    public var outputPresentationLatency: Double {
        state.withLock { $0.engine.isInManualRenderingMode ? 0 : $0.engine.outputNode.presentationLatency }
    }

    // MARK: Diagnóstico (tests)

    /// Ganancias objetivo de un canal: (fader·mute, gate de Programa, gate de solo).
    func targetGains(for id: InputID) -> ChannelGains? {
        state.withLock { state in
            state.channels[id].map {
                ChannelGains(fader: $0.fader.control.target, program: $0.programGate.control.target,
                             solo: $0.soloGate.control.target)
            }
        }
    }

    /// Ganancia aplicada (al final del último bloque) por el gate de Programa de un canal.
    func appliedProgramGain(for id: InputID) -> Float? {
        state.withLock { $0.channels[id]?.programGate.control.applied }
    }

    /// Emisiones automáticas de vúmetros desde que se creó el motor (diagnóstico y tests).
    var meterTimerFires: Int { meterPublisher.timerFires }

    /// Fuerza una emisión de vúmetros (tests).
    func publishMetersNow() { meterPublisher.publish() }

    // MARK: Privado

    private func updateSettings(_ id: InputID, _ change: (inout ChannelSettings) -> Void) {
        state.withLock { state in
            change(&state.settings[id, default: ChannelSettings()])
            Self.applyGains(&state)
        }
    }

    /// Pone el canal a 0 con rampa y programa su desmontaje.
    private func retire(_ channel: Channel, in state: inout State) {
        channel.fader.control.target = 0
        channel.programGate.control.target = 0
        channel.soloGate.control.target = 0
        guard state.engine.isRunning else {
            Self.teardown(channel, in: state.engine)
            return
        }
        let key = state.nextRetiringKey
        state.nextRetiringKey += 1
        let delay = configuration.rampDuration + Self.retireMargin
        if state.engine.isInManualRenderingMode && !state.wallClockRetirement {
            let frames = Int((delay * state.format.sampleRate).rounded(.up))
            state.retiring[key] = RetiringChannel(channel: channel, deadlineFrame: state.renderedFrames + frames)
        } else {
            state.retiring[key] = RetiringChannel(channel: channel, deadlineFrame: nil)
            scheduleFinishRetiring(key, attempt: 0, after: delay)
        }
    }

    private func scheduleFinishRetiring(_ key: Int, attempt: Int, after delay: Double) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.finishRetiring(key, attempt: attempt)
        }
    }

    /// Desmonta solo cuando el hilo de audio ya ha aplicado ganancia 0 (el reloj de pared no
    /// garantiza que la rampa haya sonado). Con el motor parado no hay render: se desmonta ya.
    private func finishRetiring(_ key: Int, attempt: Int) {
        let retry = state.withLock { state -> Bool in
            guard let entry = state.retiring[key] else { return false }
            let silent = entry.channel.fader.control.applied == 0
            guard silent || !state.engine.isRunning || attempt >= Self.retireMaxAttempts else { return true }
            if !silent && state.engine.isRunning {
                Self.logger.warning("Canal desmontado sin llegar a ganancia 0 tras \(attempt) reintentos")
            }
            state.retiring[key] = nil
            Self.teardown(entry.channel, in: state.engine)
            return false
        }
        if retry { scheduleFinishRetiring(key, attempt: attempt + 1, after: Self.retireRetryInterval) }
    }

    /// Tests: las bajas en offline siguen la ruta de tiempo real (temporizador + comprobación de
    /// ganancia aplicada) en lugar del reloj de muestras renderizadas.
    func useWallClockRetirement() { state.withLock { $0.wallClockRetirement = true } }

    private static func clampGain(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 2) : 0
    }

    private static func makeStage(gain: Float, ramp: Double, metering: Bool = false,
                                  maxDelay: Double = 0) throws -> GainStage {
        let made = try RampGainUnit.makeNode(initialGain: gain, rampSeconds: ramp, metering: metering,
                                         maxDelaySeconds: maxDelay)
        return GainStage(node: made.node, control: made.control)
    }

    /// Recalcula y publica todas las ganancias objetivo (solo atómicos; barato).
    private static func applyGains(_ state: inout State) {
        let anySolo = state.channels.keys.contains { state.settings[$0]?.solo == true }
        for (id, channel) in state.channels {
            let settings = state.settings[id] ?? ChannelSettings()
            channel.fader.control.target = settings.muted ? 0 : settings.volume
            channel.programGate.control.target = settings.followsProgram ? state.program.gain(for: id) : 1
            channel.soloGate.control.target = settings.solo ? 1 : 0
        }
        state.masterFader.control.target = state.masterVolume
        state.programListen.control.target = anySolo ? 0 : 1
        state.soloListen.control.target = anySolo ? 1 : 0
    }

    private static func buildBusGraph(_ state: inout State) {
        let engine = state.engine
        let format = state.format
        let nodes: [AVAudioNode] = [state.masterMixer, state.soloMixer, state.listenMixer,
                                    state.masterFader.node, state.programListen.node,
                                    state.soloListen.node, state.output.node]
        nodes.forEach(engine.attach)
        engine.connect(state.masterMixer, to: state.masterFader.node, format: format)
        engine.connect(state.masterFader.node, to: state.programListen.node, format: format)
        engine.connect(state.programListen.node, to: state.listenMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(state.soloMixer, to: state.soloListen.node, format: format)
        engine.connect(state.soloListen.node, to: state.listenMixer, fromBus: 0, toBus: 1, format: format)
        engine.connect(state.listenMixer, to: state.output.node, format: format)
        engine.connect(state.output.node, to: engine.mainMixerNode, format: format)
    }

    private static func connect(_ channel: Channel, in state: inout State) {
        let engine = state.engine
        let format = state.format
        // Formato de la conexión fuente → canal: si el nodo es nuestro (aún no estaba en el motor),
        // su `outputFormat` todavía es el de fábrica (44,1 kHz) y conectarlo así metería un SRC;
        // se usa el formato canónico (los `AVAudioPlayerNode`/`AVAudioSourceNode` convierten solos).
        // Si ya estaba en el motor, se respeta su formato y el mezclador `input` convierte.
        let sourceFormat = channel.source.outputFormat(forBus: 0)
        let connectFormat = !channel.ownsSourceNode && sourceFormat.sampleRate > 0 ? sourceFormat : format
        if channel.ownsSourceNode { engine.attach(channel.source) }
        channel.nodes.forEach(engine.attach)
        engine.connect(channel.source, to: channel.input, format: connectFormat)
        engine.connect(channel.input, to: channel.fader.node, format: format)
        engine.connect(channel.fader.node, to: [
            AVAudioConnectionPoint(node: channel.programGate.node, bus: 0),
            AVAudioConnectionPoint(node: channel.soloGate.node, bus: 0)
        ], fromBus: 0, format: format)
        engine.connect(channel.programGate.node, to: state.masterMixer, fromBus: 0,
                       toBus: state.masterMixer.nextAvailableInputBus, format: format)
        engine.connect(channel.soloGate.node, to: state.soloMixer, fromBus: 0,
                       toBus: state.soloMixer.nextAvailableInputBus, format: format)
    }

    private static func teardown(_ channel: Channel, in engine: AVAudioEngine) {
        engine.disconnectNodeOutput(channel.source)
        channel.nodes.forEach(engine.detach)
        if channel.ownsSourceNode { engine.detach(channel.source) }
    }
}
