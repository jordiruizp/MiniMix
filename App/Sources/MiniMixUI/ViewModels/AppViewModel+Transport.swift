import Core

/// Transporte de los monitores y la rejilla: alternar reproducción, parar y volver al inicio.
extension AppViewModel {
    /// La entrada tiene transporte (vídeo, audio o playlist); imagen y color no.
    public func hasTransport(_ id: InputID) -> Bool {
        switch descriptor(id)?.kind {
        case .video, .audio, .playlist: true
        default: false
        }
    }

    /// Alterna reproducción/pausa.
    public func togglePlayback(_ id: InputID) {
        send(isPlaying(id) ? .pause(id) : .play(id))
    }

    /// Para la entrada: pausa y vuelve al inicio (en una playlist, al inicio del item actual).
    public func stopPlayback(_ id: InputID) {
        if isPlaying(id) { send(.pause(id)) }
        send(.restart(id))
    }

    /// Vuelve al inicio sin cambiar el estado de reproducción.
    public func goToStart(_ id: InputID) {
        send(.restart(id))
    }
}
