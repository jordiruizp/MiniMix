/// Análisis de una secuencia de lecturas de código de fotograma (tests gapless).
///
/// Cuenta, entre lecturas consecutivas: negros/ilegibles, repeticiones (mismo código),
/// saltos (frames de la misma fuente que no se vieron), retrocesos y cambios de clip.
/// La cadencia esperada (p. ej. 25p sobre lienzo 60 → repeticiones 2-3-2-3) la juzga el test.
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
    public private(set) var clipChanges: [ClipChange] = []
    public private(set) var codes: [FrameCode] = []

    public init(_ readings: some Sequence<FrameCodeReading>) {
        var previous: FrameCode?
        var run = 0
        for reading in readings {
            total += 1
            guard let code = reading.code else {
                if reading.isBlack { black += 1 } else { unreadable += 1 }
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

    /// Sin negros, ilegibles, saltos ni retrocesos (las repeticiones dependen de la cadencia).
    public var isGapless: Bool { black == 0 && unreadable == 0 && skippedFrames == 0 && backwardJumps == 0 }
}
