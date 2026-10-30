import Core
import Foundation

/// Eventos de las fuentes (`FrameSource.events`, un solo consumidor por fuente).
///
/// Se suscribe al dar de alta una entrada y tras cada `update` (si Media sustituyó la fuente, la
/// identidad cambia y se suscribe a la nueva). Las suscripciones no se cancelan en `stop()`:
/// cancelar el consumidor terminaría el stream de esa fuente para siempre.
extension AppViewModel {
    func subscribeEvents(_ id: InputID) {
        guard let source = services.inputs.frameSource(for: id) else {
            unsubscribeEvents(id)
            return
        }
        let identity = ObjectIdentifier(source)
        guard sourceSubscriptions[id]?.source != identity else { return }
        sourceSubscriptions[id]?.task.cancel()
        let events = source.events
        let task = Task { [weak self] in
            for await event in events { self?.handleSourceEvent(event, from: id) }
        }
        sourceSubscriptions[id] = (identity, task)
    }

    func unsubscribeEvents(_ id: InputID) {
        sourceSubscriptions[id]?.task.cancel()
        sourceSubscriptions[id] = nil
    }

    func handleSourceEvent(_ event: SourceEvent, from id: InputID) {
        guard let input = descriptor(id) else { return }
        switch event {
        case .durationKnown(let effective):
            // Media informa la duración útil (con recortes); la UI guarda la del archivo.
            guard input.outPoint == nil, let path = input.content.mediaReference?.path else { return }
            setMediaDuration(effective + (input.inPoint ?? 0), forPath: path)
        case .ended:
            // Con bucle la fuente vuelve a empezar sola (no debería emitir `.ended`).
            guard !input.loop else { return }
            playback[id, default: PlaybackInfo()].end(at: now)
        case .error(let message):
            errorMessage = "«\(input.name)»: \(message)"
        case .itemChanged(let item):
            playlists.sourceItemChanged(item, for: id)
        }
    }

    /// Posición real de la fuente (contracts-v2 `currentTime`), si la informa.
    func sourcePosition(_ id: InputID) -> Double? {
        services.inputs.frameSource(for: id)?.currentTime
    }
}
