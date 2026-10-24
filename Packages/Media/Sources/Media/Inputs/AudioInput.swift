import AVFoundation
import Core
import Foundation
import Metal

/// Entrada de solo audio (T32): WAV, AIFF, MP3, AAC/M4A con `AVAudioFile` +
/// `AVAudioPlayerNode`.
///
/// - `node` lo adjunta y conecta Audio (E) a su canal (`AudioEngine.attach`);
///   `AVAudioPlayerNode` convierte el archivo al formato de la conexión.
/// - Play/Pause/Restart/Loop e In/Out. El bucle es sin huecos: siempre hay un
///   segmento más programado en el nodo.
/// - Visual: la fuente inyectada (`ColorInput` negro o `ImageInput` de cartela).
/// - `play()` antes de que el nodo esté en un motor en marcha queda pendiente y
///   arranca en cuanto lo está (sondeo ligero cada 50 ms, fuera del render).
public final class AudioInput: FrameSource, AudioSource {
    private struct State {
        var file: AVAudioFile?
        var playback: PlaybackState = .idle
        var wantsPlay = false
        var loop: Bool
        var inPoint: Double?
        var outPoint: Double?
        var duration: Double?
        /// Invalida las finalizaciones de segmentos programados antes de un stop/seek.
        var generation = 0
        var queuedSegments = 0
        /// Segmentos programados en el nodo, en orden (segundos del archivo).
        var segments: [Segment] = []
        /// Duración de los segmentos ya reproducidos desde el último `stop` del nodo
        /// (el `sampleTime` del nodo es acumulado desde entonces).
        var finishedSeconds: Double = 0
        /// Última posición conocida (pausa, seek, final).
        var lastPosition: Double?
        /// Posición desde la que programar al arrancar (nil = In).
        var startPosition: Double?
        var pendingStart = false
    }

    private struct Segment {
        let start: Double
        let duration: Double
    }

    public let id: InputID
    public let url: URL
    public let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation
    private let playerRef = SendableAudioNode(node: AVAudioPlayerNode())
    private var player: AVAudioPlayerNode { playerRef.node }
    /// Las finalizaciones de segmento se procesan aquí, nunca dentro del callback:
    /// AVAudioPlayerNode puede invocarlo con el cerrojo del motor tomado (stop,
    /// desmontaje) y volver a programar desde ahí produce un interbloqueo.
    private let completionQueue = DispatchQueue(label: "minimix.audioinput.completion", qos: .userInitiated)
    private let visual: FrameSource?
    private let state: LockedState<State>

    /// - Parameter visual: lo que se ve en vídeo (nil = transparente).
    public init(id: InputID = InputID(), url: URL, visual: FrameSource?,
                loop: Bool = false, inPoint: Double? = nil, outPoint: Double? = nil) {
        self.id = id
        self.url = url
        self.visual = visual
        state = LockedState(State(loop: loop, inPoint: inPoint, outPoint: outPoint))
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    deinit { continuation.finish() }

    public var node: AVAudioNode? { player }
    public var nativeSize: PixelSize { visual?.nativeSize ?? PixelSize(width: 16, height: 9) }
    public var playbackState: PlaybackState { state.withLock { $0.playback } }
    public var duration: Double? { state.withLock { $0.duration } }
    /// true si el nodo está sonando (o tiene segmentos y está en play).
    public var isNodePlaying: Bool { player.isPlaying }
    var transportForTesting: TransportSettings {
        state.withLock { TransportSettings(loop: $0.loop, inPoint: $0.inPoint, outPoint: $0.outPoint) }
    }

    /// Posición en el archivo (s). Con el nodo sonando la calcula con
    /// `playerTime(forNodeTime:)` (solo toma el cerrojo corto del motor; no es para el
    /// hilo de render); en pausa devuelve la última posición conocida.
    public var currentTime: Double? {
        struct Snapshot {
            let front: Segment?
            let finished: Double
            let fallback: Double
            let playing: Bool
        }
        let snapshot = state.withLock { s -> Snapshot? in
            guard s.file != nil else { return nil }
            return Snapshot(front: s.segments.first, finished: s.finishedSeconds,
                            fallback: s.startPosition ?? s.lastPosition ?? s.inPoint ?? 0,
                            playing: s.playback == .playing)
        }
        guard let snapshot else { return nil }
        guard snapshot.playing, let front = snapshot.front, player.engine != nil,
              let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return snapshot.fallback }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        let position = front.start + min(max(0, elapsed - snapshot.finished), front.duration)
        state.withLock { $0.lastPosition = position }
        return position
    }

    public func prepare() async throws {
        if state.withLock({ $0.file != nil }) { return }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            let message = "\(url.lastPathComponent): \(error.localizedDescription)"
            continuation.yield(.error(message))
            throw MediaError.unreadable(message)
        }
        try await visual?.prepare()
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        let effective = state.withLock { s -> Double in
            s.file = file
            s.duration = seconds
            if s.playback == .idle { s.playback = s.wantsPlay ? .playing : .paused }
            return max(0, min(s.outPoint ?? seconds, seconds) - (s.inPoint ?? 0))
        }
        continuation.yield(.durationKnown(effective))
        if state.withLock({ $0.wantsPlay }) { play() }
    }

    public func texture(for time: HostTime) -> MTLTexture? { visual?.texture(for: time) }

    public func play() {
        let ended = state.withLock { s -> Bool in
            defer {
                s.wantsPlay = true
                s.playback = .playing
            }
            return s.playback == .ended
        }
        if ended { reschedule(from: nil) }
        startNodeIfPossible()
    }

    public func pause() {
        let position = currentTime
        state.withLock { s in
            s.lastPosition = position
            s.wantsPlay = false
            s.pendingStart = false
            if s.playback == .playing { s.playback = .paused }
        }
        if player.engine != nil { player.pause() }
    }

    public func seek(to seconds: Double) async {
        reschedule(from: seconds)
        state.withLock { s in
            if s.playback == .ended { s.playback = s.wantsPlay ? .playing : .paused }
        }
        startNodeIfPossible()
    }

    /// Vuelve al punto In conservando play/pausa.
    public func restart() async { await seek(to: state.withLock { $0.inPoint ?? 0 }) }

    /// Activar el bucle programa una vuelta más; desactivarlo con la vuelta siguiente
    /// ya en cola reprograma desde la posición actual (micro-corte inaudible en la
    /// práctica) para que no suene una vuelta de más.
    public func setLoop(_ loop: Bool) {
        let (extraGeneration, dropQueued) = state.withLock { s -> (Int?, Bool) in
            s.loop = loop
            if loop { return (s.queuedSegments == 1 ? s.generation : nil, false) }
            return (nil, s.queuedSegments > 1)
        }
        if let extraGeneration { scheduleSegment(from: nil, generation: extraGeneration) }
        if dropQueued {
            reschedule(from: currentTime)
            startNodeIfPossible()
        }
    }

    public func setInOut(inPoint: Double?, outPoint: Double?) {
        state.withLock { s in
            s.inPoint = inPoint
            s.outPoint = outPoint
        }
    }

    // MARK: Programación de segmentos

    /// Vacía el nodo y deja la posición de arranque en `seconds` (nil = In). Los
    /// segmentos se programan al arrancar (`startNodeIfPossible`), cuando el nodo
    /// ya está en un motor (programar en un nodo sin motor no es válido).
    private func reschedule(from seconds: Double?) {
        state.withLock { s in
            s.generation += 1
            s.queuedSegments = 0
            s.segments = []
            s.finishedSeconds = 0
            s.startPosition = seconds
            s.lastPosition = seconds ?? s.inPoint ?? 0
        }
        if player.engine != nil { player.stop() }
    }

    /// Programa un segmento [from|In, Out) del archivo.
    private func scheduleSegment(from seconds: Double?, generation: Int) {
        struct Scheduled {
            let file: AVAudioFile
            let start: AVAudioFramePosition
            let count: AVAudioFrameCount
        }
        let segment = state.withLock { s -> Scheduled? in
            guard let file = s.file, s.generation == generation else { return nil }
            let rate = file.processingFormat.sampleRate
            let length = file.length
            let lower = AVAudioFramePosition(((seconds ?? s.inPoint ?? 0) * rate).rounded())
            let upper = s.outPoint.map { AVAudioFramePosition(($0 * rate).rounded()) } ?? length
            let start = min(max(lower, 0), length)
            let end = min(max(upper, start), length)
            guard end > start else { return nil }
            s.queuedSegments += 1
            s.segments.append(Segment(start: Double(start) / rate, duration: Double(end - start) / rate))
            return Scheduled(file: file, start: start, count: AVAudioFrameCount(end - start))
        }
        guard let segment else { return }
        guard player.engine != nil else {
            state.withLock { s in
                s.queuedSegments -= 1
                s.segments.removeLast()
            }
            return
        }
        player.scheduleSegment(segment.file, startingFrame: segment.start, frameCount: segment.count, at: nil,
                               completionCallbackType: .dataRendered) { [weak self] _ in
            self?.completionQueue.async { [weak self] in self?.segmentFinished(generation: generation) }
        }
    }

    private func segmentFinished(generation: Int) {
        enum Next { case none, scheduleMore, ended }
        let next = state.withLock { s -> Next in
            guard s.generation == generation else { return .none }
            s.queuedSegments -= 1
            if !s.segments.isEmpty {
                let done = s.segments.removeFirst()
                s.finishedSeconds += done.duration
                s.lastPosition = done.start + done.duration
            }
            if s.loop { return .scheduleMore }
            guard s.queuedSegments <= 0 else { return .none }
            s.playback = .ended
            s.wantsPlay = false
            s.startPosition = nil
            return .ended
        }
        switch next {
        case .none: break
        case .scheduleMore: scheduleSegment(from: nil, generation: generation)
        case .ended: continuation.yield(.ended)
        }
    }

    /// Arranca el nodo si está en un motor en marcha; si no, sondea hasta que lo esté.
    private func startNodeIfPossible() {
        guard state.withLock({ $0.wantsPlay && $0.file != nil }) else { return }
        guard let engine = player.engine, engine.isRunning else {
            let shouldPoll = state.withLock { s -> Bool in
                defer { s.pendingStart = true }
                return !s.pendingStart
            }
            if shouldPoll { pollForEngine() }
            return
        }
        let (generation, needsSchedule, position, loop) = state.withLock { s in
            s.pendingStart = false
            defer { s.startPosition = nil }
            return (s.generation, s.queuedSegments == 0, s.startPosition, s.loop)
        }
        if needsSchedule {
            scheduleSegment(from: position, generation: generation)
            if loop { scheduleSegment(from: nil, generation: generation) }
        }
        player.play()
    }

    private func pollForEngine() {
        Task { [weak self] in
            while let self, self.state.withLock({ $0.pendingStart && $0.wantsPlay }) {
                if let engine = self.player.engine, engine.isRunning {
                    self.state.withLock { $0.pendingStart = false }
                    self.startNodeIfPossible()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.state.withLock { $0.pendingStart = false }
        }
    }
}
