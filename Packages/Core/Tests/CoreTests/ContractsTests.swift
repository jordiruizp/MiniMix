import Core
import CoreMocks
import Foundation
import Testing

@Suite("Contratos v1")
struct ContractsTests {
    @Test func projectRoundTripsThroughJSON() throws {
        let project = SampleData.project
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.schemaVersion == Project.currentSchemaVersion)
    }

    @Test func commandRoundTripsThroughJSON() throws {
        let id = InputID()
        let commands: [Command] = [.selectPreview(id), .cut, .fade(duration: 1.5), .tbar(0.4),
                                   .setVolume(id, 0.5), .playlistJump(id, ItemID()), .seek(id, seconds: 3)]
        for cmd in commands {
            let decoded = try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(cmd))
            #expect(decoded == cmd)
        }
    }

    @Test func inputKindDerivesFromContent() {
        #expect(InputContent.color(.black).kind == .color)
        #expect(InputContent.playlist(Playlist()).kind == .playlist)
    }

    @Test(arguments: [0.0, 0.25, 0.5, 0.75, 1.0])
    func audioCurveIsEqualPower(progress: Double) {
        let gains = TransitionCurve.audioGains(progress)
        #expect(abs(gains.outgoing * gains.outgoing + gains.incoming * gains.incoming - 1) < 1e-9)
    }

    @Test func videoCurveEndpoints() {
        #expect(TransitionCurve.videoMix(0) == 0)
        #expect(TransitionCurve.videoMix(1) == 1)
        #expect(TransitionCurve.videoMix(0.5) == 0.5)
        #expect(TransitionCurve.videoMix(-1) == 0)
    }

    @Test func frameRateMath() {
        #expect(abs(FrameRate.fps29_97.fps - 29.97) < 0.001)
        #expect(FrameRate.fps25.frameDuration == 0.04)
    }

    @Test func mockSwitcherSwapsOnCut() {
        let a = InputID(), b = InputID()
        var sw = MockSwitcher(preview: a, program: b)
        _ = sw.apply(.cut, at: .zero)
        #expect(sw.program == a && sw.preview == b)
    }

    @Test func mockClockAdvancesOneFrame() {
        let clock = MockClock(frameRate: .fps25)
        clock.advance(frames: 2)
        #expect(abs(clock.now.seconds - 0.08) < 1e-9)
    }
}

#if canImport(Metal)
import Metal

@Test func mockFrameSourceProducesTexture() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let src = MockFrameSource(color: RGBAColor(red: 1, green: 0, blue: 0))
    try await src.prepare()
    #expect(src.texture(for: .zero) != nil)
}
#endif
