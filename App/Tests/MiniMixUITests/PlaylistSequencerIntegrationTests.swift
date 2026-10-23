import Core
import CoreMocks
import Foundation
import Testing
@testable import MiniMixUI

@Suite("Panel de playlist con PlaylistSequencer real")
@MainActor
struct PlaylistSequencerIntegrationTests {
    private static func project(_ playlist: Playlist) -> (Project, InputID) {
        let input = InputDescriptor(name: "PL", content: .playlist(playlist))
        let other = InputDescriptor(name: "Color", content: .color(.black))
        return (Project(inputs: [input, other], preview: input.id, program: other.id), input.id)
    }

    private static func still(_ seconds: Double, stopAfter: Bool = false) -> PlaylistItem {
        PlaylistItem(source: .color(.black), duration: seconds, stopAfter: stopAfter)
    }

    @Test func singleItemLoopRestartsItemClock() {
        let (project, id) = Self.project(Playlist(items: [Self.still(4)], loop: true))
        let harness = Harness(project: project, spySequencer: false)
        harness.app.send(.play(id))
        harness.advance(to: 3)
        #expect(harness.app.playlists.itemRemaining(for: id) == 1)
        harness.advance(to: 4.5) // fin del item → playing(0) otra vez
        #expect(harness.app.playlists.currentIndex(for: id) == 0)
        #expect(harness.app.playlists.itemElapsed(for: id) == 0)
        harness.advance(to: 5.5)
        #expect(harness.app.playlists.itemRemaining(for: id) == 3)
    }

    @Test func previousOnFirstItemRestartsClock() {
        let (project, id) = Self.project(Playlist(items: [Self.still(10), Self.still(10)]))
        let harness = Harness(project: project, spySequencer: false)
        harness.app.send(.play(id))
        harness.advance(to: 6)
        harness.app.playlists.previous(id)
        #expect(harness.app.playlists.itemRemaining(for: id) == 10)
    }

    @Test func nextFromHeldResumesPlayback() {
        let (project, id) = Self.project(Playlist(items: [Self.still(2, stopAfter: true), Self.still(5), Self.still(5)]))
        let harness = Harness(project: project, spySequencer: false)
        harness.app.send(.play(id))
        harness.advance(to: 2.5)
        #expect(harness.app.playlists.isHeld(id))
        #expect(!harness.app.isPlaying(id))
        #expect(harness.app.playlists.itemRemaining(for: id) == 0)
        harness.app.playlists.next(id)
        #expect(harness.app.playlists.currentIndex(for: id) == 1)
        #expect(harness.app.isPlaying(id))
        harness.advance(to: 4.5)
        #expect(harness.app.playlists.itemRemaining(for: id) == 3)
    }

    @Test func playAfterExplicitPauseInHeldStartsCuedItem() {
        let (project, id) = Self.project(Playlist(items: [Self.still(2, stopAfter: true), Self.still(5)]))
        let harness = Harness(project: project, spySequencer: false)
        harness.app.send(.play(id))
        harness.advance(to: 2.5)
        #expect(harness.app.playlists.isHeld(id))
        harness.app.send(.pause(id)) // pausa explícita estando en espera
        harness.app.send(.play(id))
        #expect(harness.app.playlists.currentIndex(for: id) == 1)
        #expect(!harness.app.playlists.isHeld(id))
        #expect(harness.app.isPlaying(id))
        harness.advance(to: 3.5)
        #expect(harness.app.playlists.itemRemaining(for: id) == 4)
    }

    @Test func deletingCurrentItemMovesClockToSuccessor() throws {
        let (project, id) = Self.project(Playlist(items: [Self.still(10), Self.still(7), Self.still(3)]))
        let harness = Harness(project: project, spySequencer: false)
        harness.app.send(.play(id))
        harness.advance(to: 4)
        let current = try #require(harness.app.playlists.playlist(for: id)?.items.first)
        harness.app.playlists.removeItems(in: id, withIDs: [current.id])
        #expect(harness.app.playlists.currentIndex(for: id) == 0)
        #expect(harness.app.playlists.itemRemaining(for: id) == 7)
        #expect(harness.app.playlists.playlistRemaining(for: id) == 10)
    }

    @Test func reorderKeepsCurrentItemAndClock() throws {
        let (project, id) = Self.project(Playlist(items: [Self.still(10), Self.still(7)]))
        let harness = Harness(project: project, spySequencer: false)
        harness.app.send(.play(id))
        harness.advance(to: 4)
        harness.app.playlists.moveItems(in: id, from: IndexSet(integer: 1), to: 0)
        #expect(harness.app.playlists.currentIndex(for: id) == 1)
        #expect(harness.app.playlists.itemRemaining(for: id) == 6)
    }

    @Test func endedPlaylistHasZeroRemaining() {
        let (project, id) = Self.project(Playlist(items: [Self.still(1)]))
        let harness = Harness(project: project, spySequencer: false)
        harness.app.send(.play(id))
        harness.advance(to: 2)
        #expect(harness.app.playlists.state(for: id) == .ended)
        #expect(harness.app.playlists.playlistRemaining(for: id) == 0)
        #expect(harness.app.playback[id]?.state == .ended)
    }

    @Test func disabledItemsAreSkipped() throws {
        let (project, id) = Self.project(Playlist(items: [Self.still(1), Self.still(2), Self.still(3)]))
        let harness = Harness(project: project, spySequencer: false)
        let second = try #require(harness.app.playlists.playlist(for: id)?.items[1])
        harness.app.playlists.setEnabled(false, item: second.id, in: id)
        harness.app.send(.play(id))
        #expect(harness.app.playlists.nextIndex(for: id) == 2)
        harness.app.playlists.next(id)
        #expect(harness.app.playlists.currentIndex(for: id) == 2)
    }
}
