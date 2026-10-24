import AVFoundation
import Core
import Foundation
import Metal
import Testing
@testable import Media

typealias Spec = TestMediaFactory.VideoSpec

extension MediaSerialTests {
    @Suite(.enabled(if: GPU.available), .timeLimit(.minutes(2)))
    struct VideoInputTests {
        let cache: VideoTextureCache

        init() {
            cache = VideoTextureCache(context: GPU.context!)
        }

        static let formats: [Spec] = [
            Spec(codec: .h264, width: 320, height: 180, fps: 30, seconds: 1, container: .mp4),
            Spec(codec: .h264, width: 320, height: 180, fps: 30, seconds: 1, container: .m4v),
            Spec(codec: .hevc, width: 320, height: 180, fps: 30, seconds: 1),
            Spec(codec: .hevcAlpha, width: 320, height: 180, fps: 30, seconds: 1),
            Spec(codec: .proRes422, width: 320, height: 180, fps: 30, seconds: 1)
        ]

        @Test(arguments: formats)
        func decodesFormatZeroCopy(spec: Spec) async throws {
            let url = try await TestMediaFactory.shared.video(spec)
            let input = VideoInput(url: url, textureCache: cache)
            try await input.prepare()
            #expect(input.nativeSize == PixelSize(width: 320, height: 180))
            #expect(abs((input.duration ?? 0) - 1) < 0.05)
            #expect(input.playbackState == .paused)
            let texture = try #require(await waitForTexture(input))
            #expect(texture.pixelFormat == .bgra8Unorm)
            #expect(texture.width == 320 && texture.height == 180)
            // Cero copias: la textura es una vista del IOSurface del decodificador.
            #expect(texture.iosurface != nil)
            #expect(input.node == nil)
        }

        @Test func emitsDurationKnownAndEnded() async throws {
            let url = try await TestMediaFactory.shared.video(Spec(width: 320, height: 180, fps: 30, seconds: 1))
            let input = VideoInput(url: url, textureCache: cache)
            let events = input.events
            try await input.prepare()
            let known = await firstEvent(events) { if case .durationKnown = $0 { true } else { false } }
            if case .durationKnown(let d) = known { #expect(abs(d - 1) < 0.05) } else { Issue.record("sin durationKnown") }
            input.play()
            #expect(input.playbackState == .playing)
            let ended = await firstEvent(events, timeout: 4) { $0 == .ended }
            #expect(ended == .ended)
            #expect(input.playbackState == .ended)
            #expect(!input.isDecoding)
            // play() tras el final vuelve a empezar.
            input.play()
            try await Task.sleep(for: .milliseconds(300))
            #expect(input.playbackState == .playing)
            input.pause()
            #expect(input.playbackState == .paused)
        }

        @Test func loopsWithoutEnding() async throws {
            let url = try await TestMediaFactory.shared.video(Spec(width: 320, height: 180, fps: 30, seconds: 1))
            let input = VideoInput(url: url, textureCache: cache, loop: true)
            let events = input.events
            try await input.prepare()
            input.play()
            let ended = await firstEvent(events, timeout: 2.5) { $0 == .ended }
            #expect(ended == nil)
            #expect(input.playbackState == .playing)
            input.pause()
        }

        @Test func inAndOutPoints() async throws {
            let url = try await TestMediaFactory.shared.video(Spec(width: 320, height: 180, fps: 30, seconds: 2))
            let input = VideoInput(url: url, textureCache: cache, inPoint: 0.5, outPoint: 1.0)
            let events = input.events
            try await input.prepare()
            let known = await firstEvent(events) { if case .durationKnown = $0 { true } else { false } }
            if case .durationKnown(let d) = known { #expect(abs(d - 0.5) < 0.01) } else { Issue.record("sin durationKnown") }
            input.play()
            let start = Date()
            // Consumir fotogramas mientras reproduce para registrar los PTS.
            var firstPTS: Double?
            let consumer = Task {
                while !Task.isCancelled {
                    _ = input.texture(for: HostClock.hostTime(nanos: HostClock.nowNanos()))
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
            while firstPTS == nil, Date().timeIntervalSince(start) < 1 {
                firstPTS = input.stats.lastPresentationTime
                try? await Task.sleep(for: .milliseconds(5))
            }
            let ended = await firstEvent(events, timeout: 3) { $0 == .ended }
            consumer.cancel()
            #expect(ended == .ended)
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed > 0.35 && elapsed < 1.5)
            #expect((firstPTS ?? 0) >= 0.49)
            #expect((input.stats.lastPresentationTime ?? 9) <= 1.0 + 1e-3)
            // restart vuelve al In.
            await input.restart()
            #expect(input.playbackState == .paused)
        }

        @Test func seekClampsAndShowsFrame() async throws {
            let url = try await TestMediaFactory.shared.video(Spec(width: 320, height: 180, fps: 30, seconds: 2))
            let input = VideoInput(url: url, textureCache: cache)
            try await input.prepare()
            _ = await waitForTexture(input)
            await input.seek(to: 1.5)
            try await Task.sleep(for: .milliseconds(100))
            _ = input.texture(for: HostClock.hostTime(nanos: HostClock.nowNanos()))
            #expect(abs((input.stats.lastPresentationTime ?? 0) - 1.5) < 0.05)
        }

        @Test func concurrentPrepareLoadsOnce() async throws {
            let url = try await TestMediaFactory.shared.video(Spec(width: 320, height: 180, fps: 30, seconds: 2))
            let input = VideoInput(url: url, textureCache: cache)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<5 { group.addTask { try await input.prepare() } }
                try await group.waitForAll()
            }
            #expect(input.loadCountForTesting == 1)
            try await input.prepare()
            #expect(input.loadCountForTesting == 1)
        }

        @Test func currentTimeTracksPlayback() async throws {
            let url = try await TestMediaFactory.shared.video(Spec(width: 320, height: 180, fps: 30, seconds: 2))
            let input = VideoInput(url: url, textureCache: cache, inPoint: 0.5)
            #expect(input.currentTime == nil)
            try await input.prepare()
            #expect(abs((input.currentTime ?? -1) - 0.5) < 0.05)
            input.play()
            try await Task.sleep(for: .milliseconds(400))
            input.pause()
            let t = try #require(input.currentTime)
            #expect(t > 0.7 && t < 1.5)
            await input.seek(to: 1.25)
            #expect(abs((input.currentTime ?? -1) - 1.25) < 0.05)
        }

        @Test func missingFileFails() async throws {
            let input = VideoInput(url: URL(fileURLWithPath: "/nonexistent/clip.mov"), textureCache: cache)
            let events = input.events
            await #expect(throws: MediaError.self) { try await input.prepare() }
            let error = await firstEvent(events, timeout: 1) { if case .error = $0 { true } else { false } }
            #expect(error != nil)
            #expect(input.texture(for: .zero) == nil)
        }

        /// Pistas a 48 kHz y a 44,1 kHz: el tap entrega la frecuencia de la pista (sin desajuste).
        @Test(arguments: [48_000, 44_100])
        func audioTrackIsExposedAsNode(rate: Int) async throws {
            let url = try await TestMediaFactory.shared.video(Spec(width: 320, height: 180, fps: 30, seconds: 2, audio: true,
                                                                   audioSampleRate: rate))
            let input = VideoInput(url: url, textureCache: cache)
            try await input.prepare()
            let node = try #require(input.node as? AVAudioSourceNode)

            // Como AudioEngine (E): conectar en el formato canónico de salida (aquí 44,1 kHz,
            // distinto del de la pista: el nodo convierte).
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            input.play()
            // El tap se alimenta en tiempo real desde el AVPlayer: sondear hasta 3 s
            // (con la máquina cargada el reproductor tarda en arrancar el audio).
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
            var peak: Float = 0
            for _ in 0..<30 where peak <= 0.1 {
                try await Task.sleep(for: .milliseconds(100))
                #expect(try engine.renderOffline(4096, to: buffer) == .success)
                let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                peak = samples.map(abs).max() ?? 0
            }
            input.pause()
            engine.stop()
            #expect(peak > 0.1)
            let tap = try #require(input.audioTapForTesting)
            let mismatch = tap.ring.formatMismatch.load(ordering: .relaxed)
            #expect(!mismatch)
            #expect(tap.ring.sampleRate == Double(rate))
        }
    }
}
