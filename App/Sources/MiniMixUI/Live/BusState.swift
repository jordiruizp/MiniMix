import Core

/// Instantánea de los buses que la interfaz (MainActor) entrega al render (T80).
public struct BusState: Sendable, Equatable {
    public var preview: InputID?
    public var program: InputID?
    /// Transición en curso: saliente/entrante y progreso lineal 0…1.
    public var transition: Transition?
    /// Encaje por entrada.
    public var fits: [InputID: FitMode]

    public struct Transition: Sendable, Equatable {
        public var from: InputID?
        public var to: InputID?
        public var kind: TransitionKind
        public var progress: Double
    }

    public init(preview: InputID? = nil, program: InputID? = nil, transition: Transition? = nil,
                fits: [InputID: FitMode] = [:]) {
        self.preview = preview
        self.program = program
        self.transition = transition
        self.fits = fits
    }

    public static let empty = BusState()
}
