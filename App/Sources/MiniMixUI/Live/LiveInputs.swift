import Audio
import Core

/// Lo que `LiveInputs` necesita del motor de audio (lo cumple `AudioEngine`; los tests usan un doble).
public protocol AudioChannelHosting: AnyObject, Sendable {
    func attach(_ source: AudioSource) throws
    func detach(_ id: InputID)
    func setVolume(_ volume: Float, for input: InputID)
    func setMute(_ muted: Bool, for input: InputID)
    func setAudioFollowsProgram(_ follows: Bool, for input: InputID)
}

extension AudioEngine: AudioChannelHosting {}

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

    private func attachAudio(_ descriptor: InputDescriptor, applySettings: Bool = true) {
        guard let source = inputs.audioSource(for: descriptor.id) else {
            // Sin audio (o sustituida por contenido sin audio): no dejar un canal huérfano.
            audio.detach(descriptor.id)
            return
        }
        do {
            try audio.attach(source)
            // Si un `remove` se coló entre la consulta y el attach, deshacerlo.
            if inputs.audioSource(for: descriptor.id) !== source { audio.detach(descriptor.id) }
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
