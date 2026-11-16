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
        let wasPlaying = isPlaying(id)
        if wasPlaying { send(.pause(id)) }
        // Una playlist en espera o terminada ya está parada: reiniciarla arrancaría el item
        // en cola (regla M2 del secuenciador), justo lo contrario de un stop.
        if descriptor(id)?.kind == .playlist, !wasPlaying, playback[id]?.state != .paused { return }
        send(.restart(id))
    }

    /// Vuelve al inicio sin cambiar el estado de reproducción.
    public func goToStart(_ id: InputID) {
        send(.restart(id))
    }
}
