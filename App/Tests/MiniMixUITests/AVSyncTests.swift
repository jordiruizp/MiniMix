import AVFAudio
import CoreAudio
import Audio
import Core
import CoreMocks
import Foundation
import Media
import Metal
@testable import MiniMixUI
import Render
import Testing

/// Sincronía A/V en la integración: perfil por tipo de fuente, aviso de salida a VideoInput,
/// latencia de presentación de vídeo y audio de las playlists reales.
@Suite("Sincronía A/V")
@MainActor
struct AVSyncTests {
    /// Fuente con el tap alineado (como VideoInput): registra los avisos de cambio de salida.
    final class TapSource: TestFrameSource, AudioOutputAware, AudioSource, @unchecked Sendable {
        let node: AVAudioNode? = nil
        let notified = Locked(0)
        func audioOutputDidChange() { notified.withLock { $0 += 1 } }
    }

    final class Host: AudioChannelHosting, @unchecked Sendable {
        let profiles = Locked([InputID: InputSyncProfile]())
        let order = Locked([String]())
        func attach(_ source: AudioSource) throws { order.withLock { $0.append("attach") } }
        func detach(_ id: InputID) {}
        func setVolume(_ volume: Float, for input: InputID) {}
        func setMute(_ muted: Bool, for input: InputID) {}
        func setAudioFollowsProgram(_ follows: Bool, for input: InputID) {}
        func setSyncProfile(_ profile: InputSyncProfile, for input: InputID) {
            profiles.withLock { $0[input] = profile }
            order.withLock { $0.append("sync") }
        }
    }

    /// Gestor con una fuente de vídeo/audio fija por entrada.
    final class Inputs: InputManaging, @unchecked Sendable {
        let frames: [InputID: FrameSource]
        let audio = MockAudioSource(node: AVAudioPlayerNode())
        init(frames: [InputID: FrameSource]) { self.frames = frames }
        func add(_ descriptor: InputDescriptor) async throws {}
        func remove(_ id: InputID) async {}
        func update(_ descriptor: InputDescriptor) async throws {}
        func frameSource(for id: InputID) -> FrameSource? { frames[id] }
        /// El audio de una fuente con tap es la propia fuente (como VideoInput).
        func audioSource(for id: InputID) -> AudioSource? { (frames[id] as? AudioSource) ?? audio }
        func setVisible(_ ids: Set<InputID>) {}
    }

    @Test func syncProfileByKindOfSource() {
        #expect(LiveInputs.syncProfile(for: TapSource(id: InputID())) == .playerTap)
        #expect(LiveInputs.syncProfile(for: TestPlaylistSource(id: InputID())) == .playerTap)
        #expect(LiveInputs.syncProfile(for: TestFrameSource(id: InputID())) == .direct)
        #expect(LiveInputs.syncProfile(for: nil) == .direct)
    }

    @Test func attachAppliesProfileAndNotifiesVideo() async throws {
        let video = InputDescriptor(name: "V", content: .video(MediaReference(path: "/tmp/v.mov")))
        let still = InputDescriptor(name: "C", content: .color(.black))
        let tap = TapSource(id: video.id)
        let host = Host()
        let inputs = LiveInputs(inputs: Inputs(frames: [video.id: tap, still.id: TestFrameSource(id: still.id)]),
                                audio: host)
        try await inputs.add(video)
        try await inputs.add(still)
        #expect(host.profiles.current[video.id] == .playerTap)
        #expect(host.profiles.current[still.id] == .direct)
        #expect(tap.notified.current == 1)
        #expect(Array(host.order.current.prefix(2)) == ["sync", "attach"], "el perfil se fija antes del attach")
        try await inputs.update(video) // cada attach reaplica perfil y aviso
        #expect(tap.notified.current == 2)
    }
}

/// Con motor y GPU reales.
@MainActor
@Suite("Sincronía A/V · real", .serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct AVSyncLiveTests {
    @Test func playlistAudioAttachesWhileTheEngineRuns() async throws {
        let context = try #require(MetalContext.shared)
        let engine = try AudioEngine(configuration: AudioEngineConfiguration(
            renderMode: .offline(sampleRate: 48_000, maximumFrameCount: 512)))
        try engine.start()
        defer { engine.stop() }
        engine.videoPresentationLatency = FrameRate.fps60.frameDuration
        let clock = MasterClock(frameRate: .fps60)
        let environment = PlaylistEnvironment(context: context, clock: clock, canvasSize: PixelSize(width: 64, height: 36))
        let manager = InputManager(context: context, canvasSize: PixelSize(width: 64, height: 36),
                                   playlistFactory: PlaylistInput.factory(environment: environment))
        let inputs = LiveInputs(inputs: manager, audio: engine)
        let playlist = InputDescriptor(name: "PL", content: .playlist(Playlist(items: [
            PlaylistItem(source: .color(RGBAColor(red: 1, green: 0, blue: 0)), duration: 1)
        ])))
        try await inputs.add(playlist)
        #expect(engine.attachedInputs.contains(playlist.id), "el audio de la playlist se conecta")
        #expect(abs(engine.inputDelayMilliseconds(for: playlist.id) - 1_000 / 60) < 0.5, "perfil .playerTap")
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.format, frameCapacity: 512))
        _ = try engine.renderOffline(512, to: buffer)
        await inputs.remove(playlist.id)
        #expect(!engine.attachedInputs.contains(playlist.id))
    }

    static func writeWav(_ url: URL, seconds: Double = 3) throws {
        let rate = 48_000.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for index in 0..<Int(frames) { channels[channel][index] = Float(sin(2 * .pi * 440 * Double(index) / rate)) * 0.3 }
        }
        try file.write(from: buffer)
    }

    private static func audioPlaylist(_ url: URL) -> InputDescriptor {
        InputDescriptor(name: "PL", content: .playlist(Playlist(items: [
            PlaylistItem(source: .audio(MediaReference(path: url.path)), duration: 3),
            PlaylistItem(source: .color(RGBAColor(red: 1, green: 0, blue: 0)), duration: 1)
        ])))
    }

    /// Item de audio real (WAV) en una playlist dada de alta con el motor (offline) arrancado: al
    /// reproducir, su nodo se conecta al mezclador de la playlist sin NSException.
    @Test func playlistWithRealAudioItemConnectsWhileRunning() async throws {
        let context = try #require(MetalContext.shared)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av-\(UUID().uuidString).wav")
        try Self.writeWav(url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AudioEngine(configuration: AudioEngineConfiguration(
            renderMode: .offline(sampleRate: 48_000, maximumFrameCount: 512)))
        try engine.start()
        defer { engine.stop() }
        let clock = MasterClock(frameRate: .fps60)
        clock.start()
        defer { clock.stop() }
        let environment = PlaylistEnvironment(context: context, clock: clock, canvasSize: PixelSize(width: 64, height: 36))
        let manager = InputManager(context: context, canvasSize: PixelSize(width: 64, height: 36),
                                   playlistFactory: PlaylistInput.factory(environment: environment))
        let inputs = LiveInputs(inputs: manager, audio: engine)
        let playlist = Self.audioPlaylist(url)
        try await inputs.add(playlist)
        #expect(engine.attachedInputs.contains(playlist.id))
        let source = try #require(manager.frameSource(for: playlist.id) as? PlaylistInput)
        let mixer = try #require(source.node as? AVAudioMixerNode)
        source.play()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.format, frameCapacity: 512))
        var connected = false
        for _ in 0..<400 where !connected {
            _ = try engine.renderOffline(512, to: buffer)
            connected = mixer.engine?.inputConnectionPoint(for: mixer, inputBus: 0) != nil
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(connected, "el item de audio se conectó al mezclador de la playlist")
        await inputs.remove(playlist.id)
        #expect(!engine.attachedInputs.contains(playlist.id))
    }

    /// Hay dispositivo de salida de audio (la variante en tiempo real se omite sin él, p. ej. en CI).
    nonisolated static var hasOutputDevice: Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown
    }

    @Test(.enabled(if: AVSyncLiveTests.hasOutputDevice))
    func realtimePlaylistWithRealAudioItem() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av-rt-\(UUID().uuidString).wav")
        try Self.writeWav(url)
        defer { try? FileManager.default.removeItem(at: url) }
        let black = InputDescriptor(name: "Negro", content: .color(.black))
        let project = Project(canvas: CanvasFormat(size: PixelSize(width: 64, height: 36), frameRate: .fps60),
                              inputs: [black], preview: black.id, program: black.id)
        let (live, runtime) = try AppServices.live(project: project)
        var services = live
        let suite = DefaultsSuite()
        services.defaults = suite.defaults
        let app = AppViewModel(services: services)
        app.start()
        defer { app.stop() }
        runtime.audio.setMasterVolume(0)
        try #require(runtime.audio.isRunning, "motor en tiempo real arrancado")
        let playlist = Self.audioPlaylist(url)
        try await runtime.inputs.add(playlist) // con el motor en marcha
        #expect(runtime.audio.attachedInputs.contains(playlist.id))
        let source = try #require(runtime.inputs.frameSource(for: playlist.id) as? PlaylistInput)
        let mixer = try #require(source.node as? AVAudioMixerNode)
        source.play()
        #expect(await eventually(timeout: 4) {
            mixer.numberOfInputs > 0 && mixer.engine?.inputConnectionPoint(for: mixer, inputBus: 0) != nil
        })
        await runtime.inputs.remove(playlist.id)
        #expect(!runtime.audio.attachedInputs.contains(playlist.id))
    }

    @Test func videoPresentationLatencyFollowsTheFrameRate() throws {
        let (_, runtime) = try AppServices.live(project: Project(canvas: CanvasFormat(size: .hd720, frameRate: .fps25)))
        #expect(abs(runtime.audio.videoPresentationLatency - 0.04) < 1e-9)
        runtime.reconfigure(CanvasFormat(size: .hd720, frameRate: .fps50))
        #expect(abs(runtime.audio.videoPresentationLatency - 0.02) < 1e-9)
    }
}
