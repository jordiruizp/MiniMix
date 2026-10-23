import Core
import CoreMocks
import Foundation
import Testing
@testable import MiniMixUI

@Suite("Panel de playlist (T51)")
@MainActor
struct PlaylistViewModelTests {
    private func items(_ harness: Harness) -> [PlaylistItem] {
        harness.app.playlists.playlist(for: harness.playlist)?.items ?? []
    }

    @Test func reorderUpdatesProjectAndSequencer() {
        let harness = Harness()
        let ids = items(harness).map(\.id)
        harness.app.playlists.moveItems(in: harness.playlist, from: IndexSet(integer: 2), to: 0)
        #expect(items(harness).map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(harness.sequencerLog.lastPlaylist?.items.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func enableAndStopAfterPerItem() throws {
        let harness = Harness()
        let model = harness.app.playlists
        let first = try #require(items(harness).first)
        model.setEnabled(false, item: first.id, in: harness.playlist)
        #expect(items(harness).first?.enabled == false)
        model.setStopAfter(true, item: first.id, in: harness.playlist)
        #expect(items(harness).first?.stopAfter == true)
        #expect(harness.sequencerLog.lastPlaylist?.items.first?.enabled == false)
    }

    @Test func modesLoopHoldAndTransition() {
        let harness = Harness()
        let model = harness.app.playlists
        model.setMode(.stopAfterEach, in: harness.playlist)
        model.setLoop(true, in: harness.playlist)
        model.setHoldBehavior(.black, in: harness.playlist)
        model.setTransition(.fade(seconds: 5), in: harness.playlist)
        let playlist = model.playlist(for: harness.playlist)
        #expect(playlist?.mode == .stopAfterEach)
        #expect(playlist?.loop == true)
        #expect(playlist?.holdBehavior == .black)
        #expect(playlist?.itemTransition == .fade(seconds: 2))
        #expect(harness.sequencerLog.lastPlaylist == playlist)
    }

    @Test func trimsAndStillDurations() throws {
        let harness = Harness()
        let model = harness.app.playlists
        let video = try #require(items(harness).first)
        let image = items(harness)[1]
        model.setTrim(inPoint: 2, outPoint: 8, item: video.id, in: harness.playlist)
        #expect(model.duration(of: items(harness)[0]) == 6)
        model.setTrim(inPoint: 9, outPoint: 3, item: video.id, in: harness.playlist) // inválido: se ignora
        #expect(items(harness)[0].inPoint == 2)
        model.setDuration(0, item: image.id, in: harness.playlist)
        #expect(items(harness)[1].duration == 0.1)
        model.setDuration(nil, item: image.id, in: harness.playlist)
        #expect(items(harness)[1].duration == PlaylistItem.defaultStillDuration)
    }

    @Test func transportGoesThroughCommandsToSequencer() throws {
        let harness = Harness()
        let model = harness.app.playlists
        let id = harness.playlist
        let third = try #require(items(harness).last)
        model.togglePlay(id)
        #expect(harness.app.isPlaying(id))
        #expect(model.currentIndex(for: id) == 0)
        #expect(model.nextIndex(for: id) == 1)
        model.next(id)
        #expect(model.currentIndex(for: id) == 1)
        model.previous(id)
        model.restartItem(id)
        model.jump(id, to: third.id)
        #expect(model.currentIndex(for: id) == 2)
        #expect(harness.sequencerLog.events == [.play, .next, .previous, .restartItem, .jump(third.id)])
        model.togglePlay(id)
        #expect(harness.app.playback[id]?.state == .paused)
        model.togglePlay(id) // reanudar no reinicia la playlist
        #expect(harness.sequencerLog.events.last == .jump(third.id))
    }

    @Test func remainingTimesAndSimulatedItemEnd() throws {
        let harness = Harness()
        let model = harness.app.playlists
        let id = harness.playlist
        // Items: vídeo a.mp4 (12 s en los mocks) · imagen 5 s · color 3 s.
        #expect(model.playlistRemaining(for: id) == 20)
        harness.app.send(.play(id))
        harness.advance(to: 4)
        #expect(model.itemRemaining(for: id) == 8)
        #expect(model.playlistRemaining(for: id) == 16)
        #expect(harness.app.remaining(for: id) == 16)
        let image = items(harness)[1]
        model.setEnabled(false, item: image.id, in: id)
        #expect(model.playlistRemaining(for: id) == 11)
        harness.advance(to: 12.5)
        #expect(harness.sequencerLog.events.last == .itemEnded)
        #expect(model.currentIndex(for: id) == 1)
        #expect(model.itemElapsed(for: id) == 0)
    }

    @Test func dropFilesIntoPlaylist() {
        let harness = Harness()
        let urls = ["x.mp4", "y.jpg", "z.doc"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(harness.app.playlists.addItems(in: harness.playlist, from: urls, at: 0) == 2)
        let sources = items(harness).prefix(2).map(\.source)
        #expect(sources == [.video(MediaReference(path: "/tmp/x.mp4")), .image(MediaReference(path: "/tmp/y.jpg"))])
        #expect(items(harness)[1].duration == PlaylistItem.defaultStillDuration)
        harness.app.playlists.removeItems(in: harness.playlist, at: IndexSet(integer: 0))
        #expect(items(harness).count == 4)
    }
}
