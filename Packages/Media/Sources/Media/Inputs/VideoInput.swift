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
/// - Formatos: MP4/MOV/M4V con H.264, HEVC (incl. alfa) y ProRes (lo que decodifique AVFoundation).
public final class VideoInput: FrameSource, AudioSource, DecodingControllable {
    public struct Stats: Sendable, Equatable {
        /// Fotogramas nuevos convertidos en textura.
        public var deliveredFrames = 0
        /// Huecos de PTS entre fotogramas consecutivos entregados (en fotogramas del archivo).
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
        var loop: Bool
        var inPoint: Double?
        var outPoint: Double?
        var duration: Double?
        /// Último fotograma (retenido mientras se muestre).
        var current: CVMetalTexture?
        /// Fotogramas anteriores retenidos unos ticks más para que la GPU termine
        /// de leerlos antes de que su IOSurface vuelva al pool del decodificador.
        var retired: [CVMetalTexture] = []
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
    private static let retainedFrames = 3

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

    public func prepare() async throws {
        if state.withLock({ $0.prepared }) { return }
        do {
            try await load()
        } catch {
            continuation.yield(.error(String(describing: error)))
            throw error
        }
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
                        s.retired.append(previous)
                        if s.retired.count > Self.retainedFrames { s.retired.removeFirst() }
                    }
                    s.current = texture
                    Self.count(frameAt: pts, in: &s.stats)
                }
            }
        }
        return state.withLock { s in s.current.flatMap(CVMetalTextureGetTexture) }
    }

    public func play() {
        let restart = state.withLock { s -> Bool in
            let ended = s.playback == .ended
            s.wantsPlay = true
            s.playback = .playing
            return ended
        }
        if restart {
            Task {
                await self.seekToStart()
                self.applyRate()
            }
        } else {
            applyRate()
        }
    }

    public func pause() {
        state.withLock { s in
            s.wantsPlay = false
            if s.playback == .playing { s.playback = .paused }
        }
        applyRate()
    }

    public func seek(to seconds: Double) async {
        let (lower, upper) = state.withLock { ($0.inPoint ?? 0, $0.outPoint ?? $0.duration ?? .greatestFiniteMagnitude) }
        let target = min(max(seconds, lower), upper)
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        state.withLock { s in
            if s.playback == .ended { s.playback = s.wantsPlay ? .playing : .paused }
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
    }

    public var isDecoding: Bool { player.rate != 0 }

    // MARK: Internos

    private func load() async throws {
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

        let item = AVPlayerItem(asset: asset)
        item.add(output)
        var tap: PlayerAudioTap?
        if let audioTrack {
            let (bridge, mix) = try await Self.makeTap(for: audioTrack)
            await MainActor.run { item.audioMix = mix } // `audioMix` es @MainActor en el SDK
            tap = bridge
        }

        let (inPoint, outPoint) = state.withLock { ($0.inPoint, $0.outPoint) }
        if let outPoint { item.forwardPlaybackEndTime = CMTime(seconds: outPoint, preferredTimescale: 600) }
        observe(item)
        player.replaceCurrentItem(with: item)
        try await waitUntilReady(item)
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

    private static func makeTap(for track: AVAssetTrack) async throws -> (PlayerAudioTap, AVAudioMix) {
        let descriptions = try await track.load(.formatDescriptions)
        let asbd = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        return try PlayerAudioTap.make(track: track, sampleRate: asbd?.mSampleRate ?? 48_000,
                                  channels: Int(asbd?.mChannelsPerFrame ?? 2))
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
        let status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { self?.fail(item.error?.localizedDescription ?? "Error de reproducción") }
        }
        state.withLock { s in
            s.observers.append(contentsOf: [ended, failed])
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
    private func applyRate() {
        let run = state.withLock { $0.prepared && $0.wantsPlay && $0.decodingEnabled && $0.playback == .playing }
        if run, player.rate == 0 {
            player.play()
        } else if !run, player.rate != 0 {
            player.pause()
        }
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
