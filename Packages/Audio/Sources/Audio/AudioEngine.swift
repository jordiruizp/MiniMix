import AVFAudio
import Core
import Synchronization

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
/// pre-gate) y de Master (`nil`, post-Master). Silencio = `Decibels.silenceFloor`.
///
/// Concurrencia: el `AVAudioEngine` y los nodos (no `Sendable`) solo se tocan bajo `state` (Mutex);
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
    }

    public let configuration: AudioEngineConfiguration
    private let state: Mutex<State>
    private let meterPublisher: MeterPublisher

    public var meters: AsyncStream<[InputID?: [Float]]> { meterPublisher.stream }

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
            masterFader: Self.makeStage(gain: 1, ramp: ramp, metering: true),
            programListen: Self.makeStage(gain: 1, ramp: ramp),
            soloListen: Self.makeStage(gain: 0, ramp: ramp),
            output: Self.makeStage(gain: 1, ramp: ramp,
                                   maxDelay: max(0, configuration.maxLatencyCompensation))
        )
        Self.buildBusGraph(&initial)
        meterPublisher.register(initial.masterFader.control, for: nil)
        state = Mutex(initial)
    }

    deinit {
        meterPublisher.stop()
        state.withLock { $0.engine.stop() }
    }

    // MARK: Ciclo de vida

    /// Arranca el motor (y, en tiempo real, la salida de audio) y la publicación de vúmetros.
    public func start() throws {
        try state.withLock { state in
            state.engine.prepare()
            try state.engine.start()
        }
        meterPublisher.start()
    }

    public func stop() {
        meterPublisher.stop()
        state.withLock { $0.engine.stop() }
    }

    public var isRunning: Bool { state.withLock { $0.engine.isRunning } }

    /// Formato canónico del grafo: estéreo Float32 no entrelazado a la frecuencia de la salida.
    /// Las fuentes se conectan con este formato (ver `attach`).
    public var format: AVAudioFormat { state.withLock { $0.format } }

    /// Solo en modo `.offline`: renderiza `frameCount` muestras de la salida en `buffer`.
    public func renderOffline(_ frameCount: AVAudioFrameCount,
                              to buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try state.withLock { state in
            guard state.engine.isInManualRenderingMode else { throw AudioEngineError.notInManualRenderingMode }
            return try state.engine.renderOffline(frameCount, to: buffer)
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
            if let previous = state.channels.removeValue(forKey: id) {
                Self.teardown(previous, in: state.engine)
            }
            let channel = Channel(
                id: id,
                source: sourceNode,
                ownsSourceNode: sourceNode.engine == nil,
                input: AVAudioMixerNode(),
                // El fader nace a 0 y sube con rampa si el motor ya está sonando.
                fader: Self.makeStage(gain: 0, ramp: ramp, metering: true),
                programGate: Self.makeStage(gain: 0, ramp: ramp),
                soloGate: Self.makeStage(gain: 0, ramp: ramp)
            )
            if state.settings[id] == nil { state.settings[id] = ChannelSettings() }
            Self.connect(channel, in: &state)
            state.channels[id] = channel
            Self.applyGains(&state)
        }
        if let control = state.withLock({ $0.channels[id]?.fader.control }) {
            meterPublisher.register(control, for: id)
        }
    }

    /// Desconecta y elimina el canal. Los ajustes (volumen, mute…) se conservan.
    public func detach(_ id: InputID) {
        meterPublisher.unregister(id)
        state.withLock { state in
            guard let channel = state.channels.removeValue(forKey: id) else { return }
            Self.teardown(channel, in: state.engine)
            Self.applyGains(&state)
        }
    }

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

    /// Fuerza una emisión de vúmetros (tests).
    func publishMetersNow() { meterPublisher.publish() }

    // MARK: Privado

    private func updateSettings(_ id: InputID, _ change: (inout ChannelSettings) -> Void) {
        state.withLock { state in
            change(&state.settings[id, default: ChannelSettings()])
            Self.applyGains(&state)
        }
    }

    private static func clampGain(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 2) : 0
    }

    private static func makeStage(gain: Float, ramp: Double, metering: Bool = false,
                                  maxDelay: Double = 0) -> GainStage {
        let made = RampGainUnit.makeNode(initialGain: gain, rampSeconds: ramp, metering: metering,
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
