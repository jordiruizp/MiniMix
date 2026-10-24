import AVFoundation
import Core
import Foundation
import Metal
import Render
import Testing
@testable import Media

/// Motor offline que imita a AudioEngine (E): conecta en estéreo Float32 48 kHz.
final class OfflineEngine {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    init(attach node: AVAudioNode, start: Bool = true) throws {
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if start { try engine.start() }
    }

    /// Renderiza `seconds` y devuelve el pico de cada bloque de 0,1 s.
    func render(seconds: Double) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4800)!
        var peaks: [Float] = []
        for _ in 0..<Int(seconds * 10) {
            _ = try engine.renderOffline(4800, to: buffer)
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            peaks.append(samples.map(abs).max() ?? 0)
        }
        return peaks
    }
}

extension MediaSerialTests {
    @Suite(.enabled(if: GPU.available), .timeLimit(.minutes(2)))
    struct AudioInputTests {
        let context = GPU.context!

        func makeInput(_ url: URL, loop: Bool = false, inPoint: Double? = nil, outPoint: Double? = nil) -> AudioInput {
            AudioInput(url: url, visual: ColorInput(color: .black, context: context), loop: loop,
                       inPoint: inPoint, outPoint: outPoint)
        }

        static let formats: [TestMediaFactory.AudioFormatSpec] = [.wav, .aiff, .m4a]

        @Test(arguments: formats)
        func playsFormatThroughNode(format: TestMediaFactory.AudioFormatSpec) async throws {
            let url = try await TestMediaFactory.shared.audio(format, seconds: 2, sampleRate: 44_100)
            try await checkPlays(url)
        }

        @Test(.enabled(if: TestMediaFactory.hasFFmpeg))
        func playsMP3() async throws {
            try await checkPlays(try await TestMediaFactory.shared.mp3())
        }

        private func checkPlays(_ url: URL) async throws {
            let input = makeInput(url)
            let events = input.events
            try await input.prepare()
            let known = await firstEvent(events) { if case .durationKnown = $0 { true } else { false } }
            if case .durationKnown(let d) = known { #expect(abs(d - 2) < 0.06) } else { Issue.record("sin durationKnown") }
            #expect(input.node is AVAudioPlayerNode)
            let engine = try OfflineEngine(attach: input.node!)
            input.play()
            #expect(input.playbackState == .playing)
            let peaks = try engine.render(seconds: 0.5)
            #expect(peaks.dropFirst().allSatisfy { $0 > 0.3 })
            input.pause()
            #expect(input.playbackState == .paused)
            let silent = try engine.render(seconds: 0.2)
            #expect(silent.allSatisfy { $0 == 0 })
        }

        @Test func blackVisual() async throws {
            let input = makeInput(try await TestMediaFactory.shared.audio(.wav))
            try await input.prepare()
            let texture = try #require(input.texture(for: .zero))
            #expect(texture.width * 9 == texture.height * 16)
            #expect(input.nativeSize == .hd1080)
        }

        @Test func playBeforeEngineStartsWhenReady() async throws {
            let input = makeInput(try await TestMediaFactory.shared.audio(.wav))
            try await input.prepare()
            input.play()
            let engine = try OfflineEngine(attach: input.node!, start: false)
            try engine.engine.start()
            try await Task.sleep(for: .milliseconds(200))
            #expect(input.isNodePlaying)
            let peaks = try engine.render(seconds: 0.3)
            #expect(peaks.dropFirst().allSatisfy { $0 > 0.3 })
        }

        @Test func endsAndRestarts() async throws {
            let input = makeInput(try await TestMediaFactory.shared.audio(.wav, seconds: 0.5))
            let events = input.events
            try await input.prepare()
            let engine = try OfflineEngine(attach: input.node!)
            input.play()
            let peaks = try engine.render(seconds: 1)
            #expect(peaks[1] > 0.3 && peaks[9] == 0)
            let ended = await firstEvent(events, timeout: 2) { $0 == .ended }
            #expect(ended == .ended)
            #expect(input.playbackState == .ended)
            input.play()
            #expect(input.playbackState == .playing)
            let again = try engine.render(seconds: 0.3)
            #expect(again[1] > 0.3)
        }

        @Test func loopsGaplessly() async throws {
            let input = makeInput(try await TestMediaFactory.shared.audio(.wav, seconds: 0.5), loop: true)
            let events = input.events
            try await input.prepare()
            let engine = try OfflineEngine(attach: input.node!)
            input.play()
            let peaks = try engine.render(seconds: 2)
            #expect(peaks.dropFirst().allSatisfy { $0 > 0.3 })
            let ended = await firstEvent(events, timeout: 0.5) { $0 == .ended }
            #expect(ended == nil)
            #expect(input.playbackState == .playing)
        }

        @Test func currentTimeFollowsRenderedAudio() async throws {
            let input = makeInput(try await TestMediaFactory.shared.audio(.wav, seconds: 2), inPoint: 0.5)
            #expect(input.currentTime == nil)
            try await input.prepare()
            #expect(input.currentTime == 0.5)
            let engine = try OfflineEngine(attach: input.node!)
            input.play()
            _ = try engine.render(seconds: 0.5)
            #expect(abs((input.currentTime ?? 0) - 1.0) < 0.05)
            input.pause()
            #expect(abs((input.currentTime ?? 0) - 1.0) < 0.05)
            await input.seek(to: 1.5)
            #expect(input.currentTime == 1.5)
        }

        /// Desactivar el bucle con la vuelta siguiente en cola no reproduce una vuelta de más.
        @Test func disablingLoopDropsQueuedLap() async throws {
            let input = makeInput(try await TestMediaFactory.shared.audio(.wav, seconds: 0.5), loop: true)
            let events = input.events
            try await input.prepare()
            let engine = try OfflineEngine(attach: input.node!)
            input.play()
            _ = try engine.render(seconds: 0.2)
            input.setLoop(false)
            let peaks = try engine.render(seconds: 1)
            // Quedaban ~0,3 s de la vuelta actual; después, silencio (sin la vuelta en cola).
            #expect(peaks[1] > 0.3)
            #expect(peaks[5...].allSatisfy { $0 == 0 })
            let ended = await firstEvent(events, timeout: 2) { $0 == .ended }
            #expect(ended == .ended)
        }

        @Test func inOutPoints() async throws {
            let input = makeInput(try await TestMediaFactory.shared.audio(.wav, seconds: 2), inPoint: 0.5, outPoint: 1.0)
            let events = input.events
            try await input.prepare()
            let known = await firstEvent(events) { if case .durationKnown = $0 { true } else { false } }
            #expect(known == .durationKnown(0.5))
            let engine = try OfflineEngine(attach: input.node!)
            input.play()
            let peaks = try engine.render(seconds: 1)
            // 0,5 s de sonido y luego silencio.
            #expect(peaks[1...3].allSatisfy { $0 > 0.3 })
            #expect(peaks[6...].allSatisfy { $0 == 0 })
            // Tras el final, restart deja la entrada en el In, en pausa; play la arranca.
            await input.restart()
            #expect(input.playbackState == .paused)
            input.play()
            #expect(try engine.render(seconds: 0.3)[1] > 0.3)
        }

        @Test func missingFileFails() async {
            let input = makeInput(URL(fileURLWithPath: "/nonexistent/song.wav"))
            await #expect(throws: MediaError.self) { try await input.prepare() }
        }
    }
}

extension MediaSerialTests {
    @Suite(.enabled(if: GPU.available))
    struct StillInputTests {
        let context = GPU.context!

        @Test func colorInputHasCanvasAspect() async throws {
            let input = ColorInput(color: RGBAColor(red: 0, green: 0.5, blue: 1), context: context, canvasSize: .hd720)
            try await input.prepare()
            #expect(input.nativeSize == .hd720)
            let texture = try #require(input.texture(for: .zero))
            #expect(texture.width * 9 == texture.height * 16)
            try input.setColor(.black)
            #expect(input.currentColor == .black)
            #expect(input.texture(for: .zero) !== texture)
            input.play()
            #expect(input.playbackState == .playing)
        }

        @Test func imageInputDefaultLoader() async throws {
            let url = try await TestMediaFactory.shared.png(width: 400, height: 200)
            let input = ImageInput(url: url, canvasSize: .hd1080, context: context)
            try await input.prepare()
            #expect(input.nativeSize == PixelSize(width: 400, height: 200))
            #expect(input.texture(for: .zero) != nil)
        }

        @Test func imageInputUsesInjectedLoaderWithCanvasSize() async throws {
            let seen = LockedState<PixelSize?>(nil)
            let device = context.device
            let input = ImageInput(url: URL(fileURLWithPath: "/x.png"), canvasSize: .hd720) { _, size in
                seen.withLock { $0 = size }
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 4, mipmapped: false)
                return device.makeTexture(descriptor: desc)!
            }
            try await input.prepare()
            #expect(seen.current == .hd720)
            #expect(input.nativeSize == PixelSize(width: 8, height: 4))
        }

        @Test func imageInputPropagatesErrors() async {
            let input = ImageInput(url: URL(fileURLWithPath: "/nonexistent.png"), context: context)
            let events = input.events
            await #expect(throws: (any Error).self) { try await input.prepare() }
            let error = await firstEvent(events, timeout: 1) { if case .error = $0 { true } else { false } }
            #expect(error != nil)
        }
    }
}
