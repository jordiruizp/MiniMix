import Audio
import Core

/// `InputManaging` de la integración (T80): delega en el `InputManager` de Media y además
/// conecta/desconecta el audio de cada entrada en el `AudioEngine` (Media no lo hace).
/// Al sustituir una fuente (`update` con medio nuevo) el `node` cambia, así que se vuelve a conectar.
public final class LiveInputs: InputManaging {
    private let inputs: any InputManaging
    private let audio: AudioEngine

    public init(inputs: any InputManaging, audio: AudioEngine) {
        self.inputs = inputs
        self.audio = audio
    }

    public func add(_ descriptor: InputDescriptor) async throws {
        try await inputs.add(descriptor)
        attachAudio(descriptor)
    }

    public func remove(_ id: InputID) async {
        audio.detach(id)
        await inputs.remove(id)
    }

    public func update(_ descriptor: InputDescriptor) async throws {
        try await inputs.update(descriptor)
        attachAudio(descriptor)
    }

    public func frameSource(for id: InputID) -> FrameSource? { inputs.frameSource(for: id) }
    public func audioSource(for id: InputID) -> AudioSource? { inputs.audioSource(for: id) }
    public func setVisible(_ ids: Set<InputID>) { inputs.setVisible(ids) }

    private func attachAudio(_ descriptor: InputDescriptor) {
        guard let source = inputs.audioSource(for: descriptor.id) else { return }
        do {
            try audio.attach(source)
        } catch {
            LiveLog.app.error("No se pudo conectar el audio de \(descriptor.name, privacy: .public): \(error)")
        }
        audio.setVolume(descriptor.volume, for: descriptor.id)
        audio.setMute(descriptor.muted, for: descriptor.id)
        audio.setAudioFollowsProgram(descriptor.audioFollowsProgram, for: descriptor.id)
    }
}
