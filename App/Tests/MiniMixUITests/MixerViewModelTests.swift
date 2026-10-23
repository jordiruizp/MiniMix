import Core
import CoreMocks
import Testing
@testable import MiniMixUI

@Suite("Mixer")
@MainActor
struct MixerViewModelTests {
    @Test func channelsOnlyForInputsWithAudio() {
        let harness = Harness()
        let channels = harness.app.mixer.channels
        #expect(channels.map(\.id) == [harness.video, harness.playlist, harness.music])
        #expect(channels.map(\.number) == [1, 4, 5])
        #expect(channels.first?.onProgram == true)
    }

    @Test func faderSendsClampedVolume() {
        let harness = Harness()
        harness.app.mixer.setVolume(3, for: harness.music)
        #expect(harness.input(5).volume == 2)
        #expect(harness.audio.recorded.current.volumes[harness.music] == 2)
        harness.app.mixer.setVolume(0.5, for: harness.music)
        #expect(harness.app.mixer.channels.last?.volume == 0.5)
    }

    @Test func muteSoloAndMaster() {
        let harness = Harness()
        let mixer = harness.app.mixer
        mixer.toggleMute(harness.music)
        #expect(harness.input(5).muted)
        #expect(harness.audio.recorded.current.mutes[harness.music] == true)
        mixer.toggleMute(harness.music)
        #expect(!harness.input(5).muted)
        mixer.toggleSolo(harness.video)
        #expect(mixer.solos == [harness.video])
        #expect(harness.audio.recorded.current.solos[harness.video] == true)
        mixer.toggleSolo(harness.video)
        #expect(mixer.solos.isEmpty)
        mixer.setMasterVolume(0.7)
        #expect(mixer.masterVolume == 0.7)
        #expect(harness.audio.recorded.current.master == 0.7)
        mixer.setFollowsProgram(false, for: harness.music)
        #expect(mixer.channels.last?.followsProgram == false)
    }

    @Test func metersFlowFromAudioService() async throws {
        let harness = Harness()
        harness.app.start()
        defer { harness.app.stop() }
        harness.audio.emit([harness.music: [-12, -10], nil: [-6, -6]])
        for _ in 0..<200 where harness.app.mixer.masterLevels.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.app.mixer.masterLevels == [-6, -6])
        #expect(harness.app.mixer.channels.last?.levels == [-12, -10])
    }

    @Test func meterScale() {
        #expect(MixerViewModel.meterFraction(0) == 1)
        #expect(MixerViewModel.meterFraction(-30) == 0.5)
        #expect(MixerViewModel.meterFraction(-90) == 0)
    }
}
