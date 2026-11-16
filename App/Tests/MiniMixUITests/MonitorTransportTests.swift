import Core
import CoreMocks
import Foundation
import Testing
@testable import MiniMixUI

@Suite("Transporte de los monitores: alternar, parar, ir al inicio, items de playlist")
@MainActor
struct MonitorTransportTests {
    @Test func onlyVideoAudioAndPlaylistHaveTransport() {
        let harness = Harness()
        #expect(harness.app.hasTransport(harness.video))
        #expect(harness.app.hasTransport(harness.music))
        #expect(harness.app.hasTransport(harness.playlist))
        #expect(!harness.app.hasTransport(harness.image))
        #expect(!harness.app.hasTransport(harness.color))
    }

    @Test func togglePlaybackAlternatesPlayAndPause() {
        let harness = Harness()
        harness.app.togglePlayback(harness.video)
        #expect(harness.app.isPlaying(harness.video))
        harness.app.togglePlayback(harness.video)
        #expect(harness.app.playback[harness.video]?.state == .paused)
    }

    @Test func stopPausesAndReturnsToStart() {
        let harness = Harness()
        harness.app.togglePlayback(harness.video)
        harness.advance(to: 10)
        harness.app.stopPlayback(harness.video)
        #expect(harness.app.playback[harness.video]?.state == .paused)
        #expect(harness.app.playback[harness.video]?.elapsed(at: 10) == 0)
        harness.advance(to: 50) // parada: el tiempo no avanza
        #expect(harness.app.playback[harness.video]?.elapsed(at: 50) == 0)
    }

    @Test func stopWhilePausedStillReturnsToStart() {
        let harness = Harness()
        harness.app.togglePlayback(harness.video)
        harness.advance(to: 10)
        harness.app.togglePlayback(harness.video) // pausa a los 10 s
        harness.app.stopPlayback(harness.video)
        #expect(harness.app.playback[harness.video]?.state == .paused)
        #expect(harness.app.playback[harness.video]?.elapsed(at: 10) == 0)
    }

    @Test func goToStartKeepsPlaying() {
        let harness = Harness()
        harness.app.togglePlayback(harness.video)
        harness.advance(to: 10)
        harness.app.goToStart(harness.video)
        #expect(harness.app.isPlaying(harness.video))
        #expect(harness.app.playback[harness.video]?.elapsed(at: 10) == 0)
        harness.advance(to: 15) // sigue reproduciendo desde el inicio
        #expect(harness.app.playback[harness.video]?.elapsed(at: 15) == 5)
    }

    @Test func playlistStopRestartsCurrentItem() {
        let harness = Harness()
        harness.app.togglePlayback(harness.playlist)
        harness.app.stopPlayback(harness.playlist)
        #expect(harness.app.playback[harness.playlist]?.state == .paused)
        #expect(harness.sequencerLog.events.contains(.restartItem))
    }

    @Test func stopOnHeldOrEndedPlaylistDoesNotRestartIt() {
        let harness = Harness()
        harness.app.togglePlayback(harness.playlist)
        harness.app.playback[harness.playlist]?.state = .held
        harness.app.stopPlayback(harness.playlist)
        harness.app.playback[harness.playlist]?.state = .ended
        harness.app.stopPlayback(harness.playlist)
        #expect(!harness.sequencerLog.events.contains(.restartItem))
    }

    @Test func playlistGoToStartRestartsCurrentItem() {
        let harness = Harness()
        harness.app.togglePlayback(harness.playlist)
        harness.app.goToStart(harness.playlist)
        #expect(harness.app.isPlaying(harness.playlist))
        #expect(harness.sequencerLog.events.contains(.restartItem))
    }

    @Test func playlistNextAndPreviousReachSequencer() {
        let harness = Harness()
        harness.app.togglePlayback(harness.playlist)
        harness.app.send(.playlistNext(harness.playlist))
        harness.app.send(.playlistPrevious(harness.playlist))
        #expect(harness.sequencerLog.events.contains(.next))
        #expect(harness.sequencerLog.events.contains(.previous))
    }
}
