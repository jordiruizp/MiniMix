import Core
import CoreMocks
import Foundation
import SwiftUI
import Testing
@testable import MiniMixUI

@Suite("Visor de Programa: tiempo transcurrido y cuenta atrás con avisos de color")
@MainActor
struct ProgramTimeTests {
    @Test func elapsedFollowsPlaybackClock() {
        let harness = Harness()
        #expect(harness.app.elapsed(for: harness.video) == 0)
        harness.app.send(.play(harness.video))
        harness.advance(to: 10)
        #expect(harness.app.elapsed(for: harness.video) == 10)
        harness.app.send(.pause(harness.video))
        harness.advance(to: 50) // en pausa no avanza
        #expect(harness.app.elapsed(for: harness.video) == 10)
    }

    @Test func elapsedClampsToDurationAndOnlyAppliesToTransport() {
        let harness = Harness()
        harness.app.send(.play(harness.video)) // /tmp/clip.mov dura 95 s en los mocks
        harness.advance(to: 200)
        #expect(harness.app.elapsed(for: harness.video) == 95)
        #expect(harness.app.elapsed(for: harness.image) == nil)
        #expect(harness.app.elapsed(for: harness.color) == nil)
    }

    @Test func elapsedRespectsTrims() {
        let harness = Harness()
        harness.app.updateInput(harness.video) {
            $0.inPoint = 5
            $0.outPoint = 25
        }
        harness.app.send(.play(harness.video))
        harness.advance(to: 30)
        #expect(harness.app.elapsed(for: harness.video) == 20)
    }

    @Test func playlistCountdownUsesCurrentItemNotWholePlaylist() {
        let harness = Harness()
        harness.app.send(.play(harness.playlist)) // item 1: /tmp/a.mp4, 12 s en los mocks
        harness.advance(to: 4)
        #expect(harness.app.elapsed(for: harness.playlist) == 4)
        #expect(harness.app.currentItemRemaining(for: harness.playlist) == 8)
        #expect(harness.app.remaining(for: harness.playlist) == 16) // 8 + 5 + 3
    }

    @Test func videoCountdownMatchesRemaining() {
        let harness = Harness()
        harness.app.send(.play(harness.video))
        harness.advance(to: 90)
        #expect(harness.app.currentItemRemaining(for: harness.video) == 5)
    }

    @Test func countdownWarningColors() {
        #expect(Theme.countdown(remaining: nil) == nil)
        #expect(Theme.countdown(remaining: 60) == nil)
        #expect(Theme.countdown(remaining: 10) == nil)
        #expect(Theme.countdown(remaining: 9.9) == Theme.countdownWarning)
        #expect(Theme.countdown(remaining: 5) == Theme.countdownWarning)
        #expect(Theme.countdown(remaining: 4.9) == Theme.countdownCritical)
        #expect(Theme.countdown(remaining: 0) == Theme.countdownCritical)
    }

    @Test func countdownWithFramesFormatting() {
        #expect(Formatting.remaining(nil, fps: 25) == "--:--")
        #expect(Formatting.remaining(7.48, fps: 25) == "-0:07.12")
        #expect(Formatting.remaining(9.5, fps: 60) == "-0:09.30")
        #expect(Formatting.remaining(61, fps: 30) == "-1:01.00")
        #expect(Formatting.remaining(0, fps: 25) == "-0:00.00")
        #expect(Formatting.remaining(0.999, fps: 29.97) == "-0:00.29") // nunca marca fps enteros
    }

    @Test func elapsedFormattingRoundsDown() {
        #expect(Formatting.elapsed(nil) == "--:--")
        #expect(Formatting.elapsed(0.6) == "0:00")
        #expect(Formatting.elapsed(9.2) == "0:09")
        #expect(Formatting.elapsed(75) == "1:15")
        #expect(Formatting.elapsed(3_605) == "1:00:05")
    }
}
