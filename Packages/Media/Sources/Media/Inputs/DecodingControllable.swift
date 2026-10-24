/// Fuente cuya decodificación puede suspenderse sin cambiar su estado lógico
/// (`InputManager.setVisible`). Una fuente pausada así conserva `playbackState`
/// (p. ej. `.playing`) y retoma al volver a habilitarse.
///
/// Público para que otras fuentes (p. ej. `PlaylistInput`, agente D) lo adopten.
public protocol DecodingControllable: AnyObject, Sendable {
    /// true si la fuente usa un decodificador de vídeo (cuenta para el límite de 4).
    var usesVideoDecoder: Bool { get }
    func setDecodingEnabled(_ enabled: Bool)
}
