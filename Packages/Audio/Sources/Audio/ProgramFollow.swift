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
    func gain(for id: InputID) -> Float {
        let gains = TransitionCurve.audioGains(progress)
        if id == to && id == from { return 1 }
        if id == to { return Float(gains.incoming) }
        if id == from { return Float(gains.outgoing) }
        return 0
    }
}
