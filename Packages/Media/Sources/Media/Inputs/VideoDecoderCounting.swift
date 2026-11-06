/// Fuente que reserva más de un decodificador de vídeo (p. ej. una playlist, que puede
/// tener el item actual y el siguiente precargado o fundiéndose). `InputManager` lo usa
/// para el límite de 4 con un **coste fijo** (el peor caso), así que no hace falta
/// recalcular cuando la playlist precarga o funde.
///
/// Nota (M1/M2): si en el futuro una fuente avisa al `InputManager` de un cambio de coste,
/// debe hacerlo **fuera de su propio cerrojo** (el gestor toma el suyo y consulta a las
/// fuentes dentro de él).
protocol VideoDecoderCounting: AnyObject {
    /// Decodificadores de vídeo que reserva (0 si no usa vídeo).
    var videoDecoderCost: Int { get }
}

extension PlaylistInput: VideoDecoderCounting {
    /// 2 si tiene items de vídeo (actual + siguiente), 0 si no. Solo API pública.
    var videoDecoderCost: Int { usesVideoDecoder ? 2 : 0 }
}
