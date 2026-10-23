import Core
import Testing
@testable import MiniMixUI

@Suite("Atajos → Commands")
@MainActor
struct ShortcutTests {
    @Test func keyMapping() {
        #expect(ShortcutMap.action(for: KeyInput(special: .space)) == .cut)
        #expect(ShortcutMap.action(for: KeyInput(special: .enter)) == .fade)
        #expect(ShortcutMap.action(for: KeyInput(special: .left)) == .programPlaylistPrevious)
        #expect(ShortcutMap.action(for: KeyInput(special: .right)) == .programPlaylistNext)
        #expect(ShortcutMap.action(for: KeyInput(characters: "p")) == .togglePreviewPlayback)
        #expect(ShortcutMap.action(for: KeyInput(characters: "P")) == .togglePreviewPlayback)
        for digit in 1...9 {
            #expect(ShortcutMap.action(for: KeyInput(characters: "\(digit)")) == .selectInput(digit))
        }
        #expect(ShortcutMap.action(for: KeyInput(characters: "0")) == nil)
        #expect(ShortcutMap.action(for: KeyInput(characters: "x")) == nil)
        // ⌘S, ⌘1… los gestionan los menús.
        #expect(ShortcutMap.action(for: KeyInput(characters: "s", hasCommandModifiers: true)) == nil)
        #expect(ShortcutMap.action(for: KeyInput(characters: "1", hasCommandModifiers: true)) == nil)
    }

    @Test func numberSelectsInputToPreview() {
        let harness = Harness()
        #expect(harness.app.commands(for: .selectInput(3)) == [.selectPreview(harness.color)])
        #expect(harness.app.commands(for: .selectInput(9)).isEmpty)
        harness.app.perform(.selectInput(3))
        #expect(harness.project.preview == harness.color)
        #expect(harness.app.selectedInputID == harness.color)
    }

    @Test func cutAndFadeUseCurrentDuration() {
        let harness = Harness()
        #expect(harness.app.commands(for: .cut) == [.cut])
        harness.app.fadeDuration = 2.5
        #expect(harness.app.commands(for: .fade) == [.fade(duration: 2.5)])
    }

    @Test func arrowsOnlyActWhenProgramIsPlaylist() {
        let harness = Harness()
        #expect(harness.app.commands(for: .programPlaylistNext).isEmpty)
        harness.app.perform(.selectInput(4))
        harness.app.perform(.cut)
        #expect(harness.project.program == harness.playlist)
        #expect(harness.app.commands(for: .programPlaylistNext) == [.playlistNext(harness.playlist)])
        #expect(harness.app.commands(for: .programPlaylistPrevious) == [.playlistPrevious(harness.playlist)])
        harness.app.send(.play(harness.playlist))
        harness.app.perform(.programPlaylistNext)
        #expect(harness.sequencerLog.events == [.play, .next])
    }

    @Test func pTogglesPreviewPlayback() {
        let harness = Harness()
        harness.app.perform(.selectInput(1))
        #expect(harness.app.commands(for: .togglePreviewPlayback) == [.play(harness.video)])
        harness.app.perform(.togglePreviewPlayback)
        #expect(harness.app.isPlaying(harness.video))
        #expect(harness.app.commands(for: .togglePreviewPlayback) == [.pause(harness.video)])
        harness.app.perform(.togglePreviewPlayback)
        #expect(harness.app.playback[harness.video]?.state == .paused)
    }
}
