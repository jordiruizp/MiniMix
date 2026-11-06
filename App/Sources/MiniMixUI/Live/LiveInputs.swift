import Audio
import Core
import Media

/// Lo que `LiveInputs` necesita del motor de audio (lo cumple `AudioEngine`; los tests usan un doble).
public protocol AudioChannelHosting: AnyObject, Sendable {
    func attach(_ source: AudioSource) throws
    func detach(_ id: InputID)
    func setVolume(_ volume: Float, for input: InputID)
    func setMute(_ muted: Bool, for input: InputID)
    func setAudioFollowsProgram(_ follows: Bool, for input: InputID)
    func setSyncProfile(_ profile: InputSyncProfile, for input: InputID)
}

extension AudioEngine: AudioChannelHosting {}

/// Fuente cuyo audio sale por el tap alineado de Media y necesita saber cuándo cambia la salida.
public protocol AudioOutputAware: AnyObject {
    func audioOutputDidChange()
}

extension VideoInput: AudioOutputAware {}

/// `InputManaging` de la integración (T80): delega en el `InputManager` de Media y además
/// conecta/desconecta el audio de cada entrada en el `AudioEngine` (Media no lo hace).
/// Al sustituir una fuente (`update` con medio nuevo) el `node` cambia, así que se vuelve a conectar.
public final class LiveInputs: InputManaging {
    private let inputs: any InputManaging
    private let audio: any AudioChannelHosting
    private let errorContinuation: AsyncStream<String>.Continuation
    /// Errores que la UI debe mostrar (audio que no se pudo conectar…). Un solo consumidor.
    public let errors: AsyncStream<String>

    public init(inputs: any InputManaging, audio: any AudioChannelHosting) {
        self.inputs = inputs
        self.audio = audio
        (errors, errorContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// Publica un error para la UI (también lo usa `LiveRuntime`).
    public func report(_ message: String) { errorContinuation.yield(message) }

    public func add(_ descriptor: InputDescriptor) async throws {
        try await inputs.add(descriptor)
        attachAudio(descriptor)
    }

    public func remove(_ id: InputID) async {
        audio.detach(id)
        await inputs.remove(id)
    }

    /// Tras `update` solo se reconecta el nodo: el motor conserva por id los ajustes (volumen,
    /// mute, «sigue a Programa») que la UI haya cambiado mientras tanto; reaplicar los del
    /// descriptor capturado antes del `await` los pisaría con valores viejos.
    public func update(_ descriptor: InputDescriptor) async throws {
        try await inputs.update(descriptor)
        attachAudio(descriptor, applySettings: false)
    }

    public func frameSource(for id: InputID) -> FrameSource? { inputs.frameSource(for: id) }
    public func audioSource(for id: InputID) -> AudioSource? { inputs.audioSource(for: id) }
    public func setVisible(_ ids: Set<InputID>) { inputs.setVisible(ids) }

    /// `.playerTap` para el audio que sale por el tap alineado de Media (VideoInput y PlaylistInput,
    /// cuyos items de vídeo usan el mismo tap); `.direct` para el resto (audio, color, imagen).
    static func syncProfile(for source: AnyObject?) -> InputSyncProfile {
        source is AudioOutputAware || source is PlaylistSourceControlling ? .playerTap : .direct
    }

    private func attachAudio(_ descriptor: InputDescriptor, applySettings: Bool = true) {
        guard let source = inputs.audioSource(for: descriptor.id) else {
            // Sin audio (o sustituida por contenido sin audio): no dejar un canal huérfano.
            audio.detach(descriptor.id)
            return
        }
        // Sincronía A/V (plan 10.2): el perfil va ANTES del attach (los ajustes persisten por id aunque
        // no haya canal), así el canal nace con el retardo correcto y sin fundido inicial. Se reaplica
        // en cada attach porque la fuente puede haber cambiado de tipo (`update` con contenido nuevo).
        audio.setSyncProfile(Self.syncProfile(for: source), for: descriptor.id)
        do {
            try audio.attach(source)
            // Si un `remove` se coló entre la consulta y el attach, deshacerlo.
            if inputs.audioSource(for: descriptor.id) !== source {
                audio.detach(descriptor.id)
                return
            }
            // VideoInput vuelve a leer la latencia de salida del motor tras conectarse.
            // TODO(D): PlaylistInput no expone un equivalente; sus VideoInput internos la leen al arrancar.
            (source as? AudioOutputAware)?.audioOutputDidChange()
        } catch {
            LiveLog.app.error("No se pudo conectar el audio de \(descriptor.name, privacy: .public): \(error)")
            report("No se pudo conectar el audio de «\(descriptor.name)»: \(error.localizedDescription)")
        }
        guard applySettings else { return }
        audio.setVolume(descriptor.volume, for: descriptor.id)
        audio.setMute(descriptor.muted, for: descriptor.id)
        audio.setAudioFollowsProgram(descriptor.audioFollowsProgram, for: descriptor.id)
    }
}
