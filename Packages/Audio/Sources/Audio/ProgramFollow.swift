import Core

/// Estado del bus de Programa visto por el audio (T41): qué entrada sale, cuál entra y el
/// progreso de la transición. Swift puro, sin AVFAudio.
///
/// - `progress` 0…1 con la misma semántica que `TransitionState` (0 = todo `from`, 1 = todo `to`).
/// - Un corte o una transición completada es `ProgramFollow(from: anterior, to: nueva, progress: 1)`
///   (o `ProgramFollow(program:)`).
/// - Las ganancias salen de `TransitionCurve.audioGains`, la misma curva que el vídeo.
struct ProgramFollow: Equatable {
    var from: InputID?
    var to: InputID?
    var progress: Double

    init(from: InputID?, to: InputID?, progress: Double) {
        self.from = from
        self.to = to
        self.progress = min(max(progress.isFinite ? progress : 0, 0), 1)
    }

    /// Solo `program` suena (sin transición en curso).
    init(program: InputID?) {
        self.init(from: nil, to: program, progress: 1)
    }

    /// Nadie en Programa: los canales que siguen a Programa están en silencio.
    static let empty = ProgramFollow(program: nil)

    /// Entrada que está en Programa (o que lo estará al terminar la transición).
    var program: InputID? { progress >= 1 ? to : (from ?? to) }

    /// Ganancia de bus de un canal con `audioFollowsProgram == true`.
    /// En los extremos (progreso 0 o 1) la ganancia es exactamente 0/1 (cos(π/2) en coma flotante
    /// daría 6e-17 y el canal saliente no quedaría en silencio digital).
    func gain(for id: InputID) -> Float {
        if id == to && id == from { return 1 }
        if id == to { return progress <= 0 ? 0 : progress >= 1 ? 1 : Float(TransitionCurve.audioGains(progress).incoming) }
        if id == from { return progress >= 1 ? 0 : progress <= 0 ? 1 : Float(TransitionCurve.audioGains(progress).outgoing) }
        return 0
    }
}
