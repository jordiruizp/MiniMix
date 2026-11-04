import AVFAudio
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
    final class TapSource: TestFrameSource, AudioOutputAware, @unchecked Sendable {
        let notified = Locked(0)
        func audioOutputDidChange() { notified.withLock { $0 += 1 } }
    }

    final class Host: AudioChannelHosting, @unchecked Sendable {
        let profiles = Locked([InputID: InputSyncProfile]())
        func attach(_ source: AudioSource) throws {}
        func detach(_ id: InputID) {}
        func setVolume(_ volume: Float, for input: InputID) {}
        func setMute(_ muted: Bool, for input: InputID) {}
        func setAudioFollowsProgram(_ follows: Bool, for input: InputID) {}
        func setSyncProfile(_ profile: InputSyncProfile, for input: InputID) {
            profiles.withLock { $0[input] = profile }
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
        func audioSource(for id: InputID) -> AudioSource? { audio }
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

    @Test func videoPresentationLatencyFollowsTheFrameRate() throws {
        let (_, runtime) = try AppServices.live(project: Project(canvas: CanvasFormat(size: .hd720, frameRate: .fps25)))
        #expect(abs(runtime.audio.videoPresentationLatency - 0.04) < 1e-9)
        runtime.reconfigure(CanvasFormat(size: .hd720, frameRate: .fps50))
        #expect(abs(runtime.audio.videoPresentationLatency - 0.02) < 1e-9)
    }
}
