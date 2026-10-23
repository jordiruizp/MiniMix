/// Análisis de una secuencia de lecturas de código de fotograma (tests gapless).
///
/// Cuenta, entre lecturas consecutivas: negros/ilegibles, repeticiones (mismo código),
/// saltos (frames de la misma fuente que no se vieron), retrocesos y cambios de clip.
/// La cadencia esperada (p. ej. 25p sobre lienzo 60 → repeticiones 2-3-2-3) la juzga el test.
///
/// Fotogramas sin código: los items de color (p. ej. el 4.º de `playlist_mixed`) y los de audio no
/// llevan código. Para que `isGapless` siga siendo evaluable, pasa `isFiller` (p. ej.
/// `FrameSequenceAnalysis.filler(averageLuma:)` con la luminancia esperada del color): esas lecturas
/// cuentan como `filler` en lugar de como negras/ilegibles.
public struct FrameSequenceAnalysis: Equatable, Sendable {
    public struct ClipChange: Equatable, Sendable {
        /// Índice (en la secuencia analizada) del primer fotograma del nuevo clip.
        public var index: Int
        public var from: FrameCode
        public var to: FrameCode
    }

    public private(set) var total = 0
    /// Lecturas sin código cuya imagen es negra.
    public private(set) var black = 0
    /// Lecturas sin código con imagen no negra (otra fuente, transición, corrupción).
    public private(set) var unreadable = 0
    /// Fotograma igual al anterior.
    public private(set) var repeats = 0
    /// Racha máxima de un mismo código (1 = ninguna repetición).
    public private(set) var longestRun = 0
    /// Frames de la fuente saltados dentro de un mismo clip (suma de huecos).
    public private(set) var skippedFrames = 0
    public private(set) var backwardJumps = 0
    /// Frames saltados al entrar en un clip nuevo (el primer código visto del clip no es su frame 0).
    public private(set) var boundarySkips = 0
    /// Lecturas sin código aceptadas por `isFiller` (items de color/audio esperados).
    public private(set) var filler = 0
    public private(set) var clipChanges: [ClipChange] = []
    public private(set) var codes: [FrameCode] = []

    public init(_ readings: some Sequence<FrameCodeReading>, isFiller: ((FrameCodeReading) -> Bool)? = nil) {
        var previous: FrameCode?
        var run = 0
        for reading in readings {
            total += 1
            guard let code = reading.code else {
                if isFiller?(reading) == true {
                    filler += 1
                } else if reading.isBlack {
                    black += 1
                } else {
                    unreadable += 1
                }
                run = 0
                continue
            }
            codes.append(code)
            defer { previous = code }
            guard let last = previous else {
                run = 1
                longestRun = max(longestRun, run)
                continue
            }
            if code.clipID != last.clipID {
                clipChanges.append(ClipChange(index: total - 1, from: last, to: code))
                boundarySkips += code.frameIndex
                run = 1
            } else if code == last {
                repeats += 1
                run += 1
            } else if code.frameIndex > last.frameIndex {
                skippedFrames += code.frameIndex - last.frameIndex - 1
                run = 1
            } else {
                backwardJumps += 1
                run = 1
            }
            longestRun = max(longestRun, run)
        }
    }

    /// Sin negros, ilegibles, saltos (dentro de un clip o al entrar en otro) ni retrocesos.
    /// Las repeticiones dependen de la cadencia. No detecta un clip que se abandona antes de su
    /// último frame (para eso, comparar `clipChanges[i].from` con el rango del manifiesto).
    public var isGapless: Bool {
        black == 0 && unreadable == 0 && skippedFrames == 0 && backwardJumps == 0 && boundarySkips == 0
    }

    /// Filtro para lecturas sin código de un color sólido esperado, por su luminancia media (0…1).
    public static func filler(averageLuma: Double, tolerance: Double = 0.05) -> @Sendable (FrameCodeReading) -> Bool {
        { abs($0.averageLuma - averageLuma) <= tolerance }
    }
}
