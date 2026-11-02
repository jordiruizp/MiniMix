/// Fuente que puede ocupar más de un decodificador de vídeo a la vez (p. ej. una playlist
/// que precarga o funde el siguiente vídeo). `InputManager` lo usa para el límite de 4.
protocol VideoDecoderCounting: AnyObject {
    /// Decodificadores de vídeo que ocupa ahora (≥ 1 si usa vídeo).
    var activeVideoDecoderCount: Int { get }
}

extension PlaylistInput: VideoDecoderCounting {
    /// Ranuras (activa, en espera, saliente) cuya fuente decodifica vídeo; como mínimo 1
    /// si la playlist tiene vídeos. Toma solo el cerrojo corto de estado de la playlist.
    var activeVideoDecoderCount: Int {
        let sources = state.withLock { s in [s.active, s.standby, s.outgoing].compactMap { $0?.source } }
        let decoding = sources.filter { ($0 as? DecodingControllable)?.usesVideoDecoder == true }.count
        return max(decoding, usesVideoDecoder ? 1 : 0)
    }
}
