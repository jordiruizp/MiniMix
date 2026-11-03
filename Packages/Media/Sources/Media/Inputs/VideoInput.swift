import AVFoundation
import Core
import CoreVideo
import Foundation
import Metal

/// Entrada de vídeo (T31): `AVPlayer` + `AVPlayerItemVideoOutput` (BGRA, compatible
/// con Metal, IOSurface) → `CVMetalTextureCache` → `MTLTexture`, sin copias.
///
/// - `texture(for:)` elige el fotograma correspondiente al `HostTime` pedido
///   (`itemTime(forHostTime:)`); si no hay uno nuevo devuelve el último. No bloquea:
///   solo consultas a la salida de vídeo y un cerrojo corto.
/// - Play/Pause/Restart/Loop, puntos In/Out (`forwardPlaybackEndTime`).
/// - Eventos: `.durationKnown` (tras `prepare`), `.ended`, `.error`.
/// - Si el archivo trae audio, `node` es un `AVAudioSourceNode` alimentado por un
///   `MTAudioProcessingTap` (ver `PlayerAudioTap`); si no, `node == nil`.
/// - Vida de las texturas: la `MTLTexture` devuelta sigue siendo válida mientras
///   se use en un command buffer que termine antes de ~100 ms (y de 3 fotogramas
///   nuevos). **Contrato para el render (T80): como máximo 3 command buffers en
///   vuelo** (p. ej. un semáforo de 3) y no guardar texturas de un fotograma a otro.
/// - Formatos: MP4/MOV/M4V con H.264, HEVC (incl. alfa) y ProRes (lo que decodifique AVFoundation).
public final class VideoInput: FrameSource, AudioSource, DecodingControllable {
    public struct Stats: Sendable, Equatable {
        /// Fotogramas nuevos convertidos en textura.
        public var deliveredFrames = 0
        /// Saltos del **consumidor**: huecos de PTS entre fotogramas consecutivos que
        /// `texture(for:)` llegó a convertir (en fotogramas del archivo). Cuenta los
        /// fotogramas que el render no llegó a pedir a tiempo, no las pérdidas internas
        /// del decodificador (que AVFoundation no expone).
        public var droppedFrames = 0
        public var nominalFrameRate: Double = 0
        public var lastPresentationTime: Double?
    }

    private struct State {
        var nativeSize = PixelSize(width: 0, height: 0)
        var playback: PlaybackState = .idle
        var wantsPlay = false
        var decodingEnabled = true
        var prepared = false
        /// Carga en curso: `prepare()` concurrentes esperan la misma (un solo AVPlayerItem).
        var loadTask: Task<Void, Error>?
        var item: AVPlayerItem?
        /// Invalida arranques en curso (preroll) superados por otro play/pause.
        var startGeneration = 0
        var loadCount = 0
        var loop: Bool
        var inPoint: Double?
        var outPoint: Double?
        var duration: Double?
        /// Último fotograma (retenido mientras se muestre).
        var current: CVMetalTexture?
        /// Fotogramas anteriores retenidos (≥ 100 ms, entre 3 y 6) para que la GPU
        /// termine de leerlos antes de que su IOSurface vuelva al pool del decodificador.
        var retired = RetirementQueue<CVMetalTexture>()
        var stats = Stats()
        var audioTap: PlayerAudioTap?
        var observers: [NSObjectProtocol] = []
        var statusObservation: NSKeyValueObservation?
    }

    public let id: InputID
    public let url: URL
    public let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation
    private let textureCache: VideoTextureCache
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let state: LockedState<State>

    /// - Parameter textureCache: caché compartida (la de `MetalContext` cuando exista).
    public init(id: InputID = InputID(), url: URL, textureCache: VideoTextureCache,
                loop: Bool = false, inPoint: Double? = nil, outPoint: Double? = nil) {
        self.id = id
        self.url = url
        self.textureCache = textureCache
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        state = LockedState(State(loop: loop, inPoint: inPoint, outPoint: outPoint))
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .pause
        output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ])
        output.suppressesPlayerRendering = true
    }

    deinit {
        let (observers, observation) = state.withLock { ($0.observers, $0.statusObservation) }
        observers.forEach(NotificationCenter.default.removeObserver)
        observation?.invalidate()
        player.replaceCurrentItem(with: nil)
        continuation.finish()
    }

    // MARK: FrameSource

    public var nativeSize: PixelSize { state.withLock { $0.nativeSize } }
    public var playbackState: PlaybackState { state.withLock { $0.playback } }
    public var stats: Stats { state.withLock { $0.stats } }
    public var duration: Double? { state.withLock { $0.duration } }
    public var node: AVAudioNode? { state.withLock { $0.audioTap?.node } }
    public var usesVideoDecoder: Bool { true }
    var audioTapForTesting: PlayerAudioTap? { state.withLock { $0.audioTap } }

    /// Reentrante: las llamadas concurrentes comparten una única carga; si falla o se
    /// cancela, se deshace (item, salida, observadores) y una llamada posterior puede
    /// reintentarlo. Cancelar la tarea que espera cancela la carga (p. ej. `remove`
    /// durante un `add`), sin dejar cargas huérfanas.
    public func prepare() async throws {
        let task = state.withLock { s -> Task<Void, Error>? in
            if s.prepared { return nil }
            if let running = s.loadTask { return running }
            let task = Task {
                do {
                    try await self.load()
                } catch {
                    self.resetFailedLoad()
                    if !(error is CancellationError) { self.continuation.yield(.error(String(describing: error))) }
                    throw error
                }
            }
            s.loadTask = task
            return task
        }
        guard let task else { return }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Deshace una carga fallida o cancelada para poder reintentar.
    private func resetFailedLoad() {
        struct Leftovers {
            let observers: [NSObjectProtocol]
            let observation: NSKeyValueObservation?
            let item: AVPlayerItem?
        }
        let left = state.withLock { s -> Leftovers in
            defer {
                s.observers = []
                s.statusObservation = nil
                s.item = nil
                s.audioTap = nil
                s.loadTask = nil
            }
            return Leftovers(observers: s.observers, observation: s.statusObservation, item: s.item)
        }
        let (observers, observation, item) = (left.observers, left.observation, left.item)
        observers.forEach(NotificationCenter.default.removeObserver)
        observation?.invalidate()
        player.replaceCurrentItem(with: nil)
        // La salida de vídeo solo puede estar en un item: soltarla del fallido.
        if let item, item.outputs.contains(where: { $0 === output }) { item.remove(output) }
    }

    var observerCountForTesting: Int { state.withLock { $0.observers.count } }

    /// Tiempo de item que muestra el vídeo en `hostSeconds` (el de `texture(for:)`).
    func itemTimeForTesting(hostSeconds: Double) -> Double? {
        let time = output.itemTime(forHostTime: hostSeconds)
        return time.isValid ? time.seconds : nil
    }

    /// Posición actual en el archivo (s), sin bloquear; nil antes de `prepare`.
    public var currentTime: Double? {
        guard state.withLock({ $0.prepared }) else { return nil }
        let time = player.currentTime()
        return time.isValid ? time.seconds : nil
    }

    var loadCountForTesting: Int { state.withLock { $0.loadCount } }
    var isDecodingEnabledForTesting: Bool { state.withLock { $0.decodingEnabled } }
    var transportForTesting: TransportSettings {
        state.withLock { TransportSettings(loop: $0.loop, inPoint: $0.inPoint, outPoint: $0.outPoint) }
    }

    public func texture(for time: HostTime) -> MTLTexture? {
        let itemTime = output.itemTime(forHostTime: time.seconds)
        if itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime) {
            var displayTime = CMTime.invalid
            if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime),
               let texture = textureCache.makeTexture(from: buffer) {
                let pts = displayTime.isValid ? displayTime.seconds : itemTime.seconds
                state.withLock { s in
                    if let previous = s.current {
                        s.retired.retire(previous, now: HostClock.nowNanos())
                    }
                    s.current = texture
                    Self.count(frameAt: pts, in: &s.stats)
                }
                return state.withLock { s in s.current.flatMap(CVMetalTextureGetTexture) }
            }
        }
        // Sin fotograma nuevo: podar por edad lo retirado (nadie nuevo lo referencia).
        let now = HostClock.nowNanos()
        return state.withLock { s in
            s.retired.prune(now: now)
            return s.current.flatMap(CVMetalTextureGetTexture)
        }
    }

    public func play() {
        startPlaying(atHostTime: nil)
    }

    /// Arranca de forma que la posición actual se presente exactamente en `time`
    /// (p. ej. un tick del `MasterClock`): `preroll(atRate:)` y después
    /// `setRate(1, time:, atHostTime:)`.
    /// - La hora solo vale para **este** arranque: si la entrada no puede arrancar
    ///   ahora (sin preparar, oculta), arrancará después de forma inmediata, no en una
    ///   hora caducada. Una hora pasada hace más de `staleStartTolerance` se ignora.
    /// - Si ya está reproduciendo, no hace nada (no re-sincroniza).
    public func play(atHostTime time: HostTime) {
        let now = HostClock.hostTime(nanos: HostClock.nowNanos()).seconds
        startPlaying(atHostTime: time.seconds < now - Self.staleStartTolerance ? nil : time.seconds)
    }

    /// Antigüedad máxima de una hora de arranque para respetarla.
    static let staleStartTolerance = 0.1

    private func startPlaying(atHostTime host: Double?) {
        let restart = state.withLock { s -> Bool in
            let ended = s.playback == .ended
            s.wantsPlay = true
            s.playback = .playing
            return ended
        }
        if restart {
            Task {
                await self.seekToStart()
                self.applyRate(startAt: host)
            }
        } else {
            applyRate(startAt: host)
        }
    }

    public func pause() {
        state.withLock { s in
            s.wantsPlay = false
            if s.playback == .playing { s.playback = .paused }
        }
        applyRate()
        scheduleRetiredFlush()
    }

    public func seek(to seconds: Double) async {
        let (lower, upper) = state.withLock { ($0.inPoint ?? 0, $0.outPoint ?? $0.duration ?? .greatestFiniteMagnitude) }
        let target = min(max(seconds, lower), upper)
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        state.withLock { s in
            if s.playback == .ended { s.playback = s.wantsPlay ? .playing : .paused }
            s.audioTap?.ring.resetTimeline()
        }
        applyRate()
    }

    // MARK: Transporte adicional

    /// Vuelve al punto In conservando play/pausa.
    public func restart() async {
        await seekToStart()
        state.withLock { s in
            if s.playback == .ended { s.playback = s.wantsPlay ? .playing : .paused }
        }
        applyRate()
    }

    public func setLoop(_ loop: Bool) { state.withLock { $0.loop = loop } }

    /// Cambia los puntos In/Out (segundos; nil = inicio/fin del archivo).
    public func setInOut(inPoint: Double?, outPoint: Double?) {
        state.withLock { s in
            s.inPoint = inPoint
            s.outPoint = outPoint
        }
        player.currentItem?.forwardPlaybackEndTime = outPoint.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
    }

    // MARK: DecodingControllable

    public func setDecodingEnabled(_ enabled: Bool) {
        let changed = state.withLock { s -> Bool in
            defer { s.decodingEnabled = enabled }
            return s.decodingEnabled != enabled
        }
        if changed { applyRate() }
        if changed, !enabled { scheduleRetiredFlush() }
    }

    public var isDecoding: Bool { player.rate != 0 }

    var retiredCountForTesting: Int { state.withLock { $0.retired.count } }

    /// Margen tras pausar/ocultar antes de soltar los fotogramas retirados (más que lo
    /// que tardan en completarse ≤ 3 command buffers en vuelo).
    static let retiredFlushDelay: DispatchTimeInterval = .milliseconds(250)

    /// Suelta los fotogramas retirados si, pasado el margen, la entrada sigue parada.
    /// Así una entrada oculta o en pausa solo retiene su fotograma actual.
    private func scheduleRetiredFlush() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.retiredFlushDelay) { [weak self] in
            guard let self else { return }
            let stillIdle = self.state.withLock { s in !(s.wantsPlay && s.decodingEnabled && s.playback == .playing) }
            guard stillIdle else { return }
            self.state.withLock { $0.retired.removeAll() }
        }
    }

    // MARK: Internos

    private func load() async throws {
        state.withLock { $0.loadCount += 1 }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let videoTrack: AVAssetTrack?
        let audioTrack: AVAssetTrack?
        do {
            duration = try await asset.load(.duration)
            videoTrack = try await asset.loadTracks(withMediaType: .video).first
            audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        } catch {
            throw MediaError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let videoTrack else { throw MediaError.noPlayableTrack(url.lastPathComponent) }
        let (natural, transform, fps) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let oriented = natural.applying(transform)
        let size = PixelSize(width: Int(abs(oriented.width).rounded()), height: Int(abs(oriented.height).rounded()))

        try Task.checkCancellation()
        let item = AVPlayerItem(asset: asset)
        item.add(output)
        state.withLock { $0.item = item }
        var tap: PlayerAudioTap?
        if let audioTrack {
            let (sampleRate, channels) = try await Self.audioFormat(of: audioTrack)
            // El tap (nodo + MTAudioProcessingTap) se crea fuera del main actor: creado
            // dentro de `MainActor.run` el tap no recibe audio (verificado en test). Solo
            // la asignación de `audioMix`, que es @MainActor en el SDK, va al main actor.
            let events = continuation
            let (bridge, mix) = try PlayerAudioTap.make(track: audioTrack, sampleRate: sampleRate, channels: channels) { got in
                events.yield(.error("Audio a \(Int(got)) Hz en una pista declarada a \(Int(sampleRate)) Hz: se silencia"))
            }
            let handoff = ImmutableAudioMix(mix: mix)
            await MainActor.run { item.audioMix = handoff.mix }
            tap = bridge
        }

        let (inPoint, outPoint) = state.withLock { ($0.inPoint, $0.outPoint) }
        if let outPoint { item.forwardPlaybackEndTime = CMTime(seconds: outPoint, preferredTimescale: 600) }
        observe(item)
        player.replaceCurrentItem(with: item)
        try await waitUntilReady(item)
        try Task.checkCancellation()
        // El tap marca cada muestra con su tiempo de item y el render la alinea con
        // la relación host ↔ item de este timebase (el mismo reloj que el vídeo).
        tap?.ring.setTimebase(item.timebase)
        if let inPoint, inPoint > 0 {
            await player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        let seconds = duration.seconds
        let effective = max(0, min(outPoint ?? seconds, seconds) - (inPoint ?? 0))
        state.withLock { s in
            s.nativeSize = size
            s.duration = seconds
            s.audioTap = tap
            s.prepared = true
            s.stats.nominalFrameRate = Double(fps)
            if s.playback == .idle { s.playback = s.wantsPlay ? .playing : .paused }
        }
        continuation.yield(.durationKnown(effective))
        applyRate()
    }

    /// Frecuencia y canales de la pista de audio (el tap entrega la frecuencia de la pista).
    private static func audioFormat(of track: AVAssetTrack) async throws -> (Double, Int) {
        let descriptions = try await track.load(.formatDescriptions)
        let asbd = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        return (asbd?.mSampleRate ?? 48_000, Int(asbd?.mChannelsPerFrame ?? 2))
    }

    private func observe(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        let ended = center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                       object: item, queue: nil) { [weak self] _ in
            self?.handleEnd()
        }
        let failed = center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                        object: item, queue: nil) { [weak self] _ in
            self?.fail("No se pudo reproducir hasta el final")
        }
        let configuration = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.refreshAudioLatency()
        }
        let status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { self?.fail(item.error?.localizedDescription ?? "Error de reproducción") }
        }
        state.withLock { s in
            s.observers.append(contentsOf: [ended, failed, configuration])
            s.statusObservation = status
        }
    }

    private func waitUntilReady(_ item: AVPlayerItem) async throws {
        let deadline = Date().addingTimeInterval(10)
        while item.status == .unknown, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        switch item.status {
        case .readyToPlay: return
        case .failed: throw MediaError.unreadable("\(url.lastPathComponent): \(item.error?.localizedDescription ?? "?")")
        default: throw MediaError.unreadable("\(url.lastPathComponent): tiempo de carga agotado")
        }
    }

    private func handleEnd() {
        let loop = state.withLock { $0.loop }
        if loop {
            Task {
                await self.seekToStart()
                self.applyRate()
            }
        } else {
            state.withLock { s in
                s.playback = .ended
                s.wantsPlay = false
            }
            applyRate()
            continuation.yield(.ended)
        }
    }

    private func fail(_ message: String) {
        state.withLock { $0.wantsPlay = false }
        applyRate()
        continuation.yield(.error(message))
    }

    private func seekToStart() async {
        let inPoint = state.withLock { $0.inPoint ?? 0 }
        await player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Ajusta la velocidad del reproductor al estado lógico + visibilidad.
    /// `startAt` (host, s) solo se usa si este mismo ajuste arranca la reproducción.
    private func applyRate(startAt host: Double? = nil) {
        let (run, generation) = state.withLock { s -> (Bool, Int) in
            s.startGeneration += 1
            return (s.prepared && s.wantsPlay && s.decodingEnabled && s.playback == .playing, s.startGeneration)
        }
        if run, player.rate == 0 {
            start(generation: generation, atHostTime: host)
        } else if !run {
            // Pausa del transporte: el render del nodo emite silencio sin consumir.
            audioRing?.transportPaused.store(true, ordering: .relaxed)
            if player.rate != 0 { player.pause() }
        }
    }

    private var audioRing: AudioRingBuffer? { state.withLock { $0.audioTap?.ring } }

    /// Preroll (llena las tuberías de audio y vídeo) y arranque, inmediato o en `host`.
    private func start(generation: Int, atHostTime host: Double?) {
        refreshAudioLatency()
        let begin: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let current = self.state.withLock { s in
                s.startGeneration == generation && s.prepared && s.wantsPlay && s.decodingEnabled && s.playback == .playing
            }
            guard current else { return }
            if let ring = self.audioRing {
                ring.resetTimeline()
                ring.transportPaused.store(false, ordering: .relaxed)
            }
            if let host {
                self.player.setRate(1, time: .invalid, atHostTime: CMTime(seconds: host, preferredTimescale: 1_000_000_000))
            } else {
                self.player.play()
            }
        }
        guard player.status == .readyToPlay else { return begin() }
        player.preroll(atRate: 1) { _ in begin() }
    }

    /// Avisa de que la salida de audio cambió (p. ej. tras `AudioEngine.attach` del
    /// nodo o un cambio de dispositivo): vuelve a leer su latencia de presentación.
    /// También se lee en cada arranque y con `AVAudioEngineConfigurationChange`.
    public func audioOutputDidChange() { refreshAudioLatency() }

    /// Latencia de presentación de la salida del motor de E (para alinear el audio
    /// con lo que se ve en ese instante).
    private func refreshAudioLatency() {
        guard let tap = state.withLock({ $0.audioTap }), let engine = tap.node.engine else { return }
        tap.ring.outputLatency = engine.outputNode.presentationLatency
    }

    private static func count(frameAt pts: Double, in stats: inout Stats) {
        defer {
            stats.deliveredFrames += 1
            stats.lastPresentationTime = pts
        }
        guard let last = stats.lastPresentationTime, stats.nominalFrameRate > 0, pts > last else { return }
        let gap = Int(((pts - last) * stats.nominalFrameRate).rounded()) - 1
        if gap > 0 { stats.droppedFrames += gap }
    }
}

/// `AVAudioMix` es inmutable (la versión mutable no se toca tras crearla), pero el
/// SDK no la anota como `Sendable`. `@unchecked Sendable` justificado: solo se
/// usa para entregarla al main actor y asignarla a `AVPlayerItem.audioMix`.
private struct ImmutableAudioMix: @unchecked Sendable {
    let mix: AVAudioMix
}
