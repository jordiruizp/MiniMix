import Core
import Foundation
import Testing

private func time(_ seconds: Double) -> HostTime { HostTime(seconds: seconds) }

@Suite("T11 · SwitcherState")
struct SwitcherStateTests {
    let a = InputID(), b = InputID(), c = InputID()

    /// PGM = a, PVW = b.
    func makeSwitcher() -> SwitcherState { SwitcherState(preview: b, program: a) }

    // MARK: Estado inicial y selectPreview

    @Test func initialStateIsIdle() {
        let sw = makeSwitcher()
        #expect(sw.preview == b && sw.program == a && sw.transition == .idle && !sw.tbarNeedsRearm)
        #expect(SwitcherState().preview == nil && SwitcherState().program == nil)
    }

    @Test func initFromProject() {
        let project = Project(preview: b, program: a)
        let sw = SwitcherState(project: project)
        #expect(sw.preview == b && sw.program == a)
    }

    @Test func selectPreviewChangesPreview() {
        var sw = makeSwitcher()
        #expect(sw.apply(.selectPreview(c), at: .zero) == [.busesChanged(preview: c, program: a)])
        #expect(sw.preview == c && sw.program == a)
    }

    @Test func selectingSamePreviewIsNoOp() {
        var sw = makeSwitcher()
        #expect(sw.apply(.selectPreview(b), at: .zero).isEmpty)
    }

    @Test func selectPreviewCanEqualProgram() {
        var sw = makeSwitcher()
        _ = sw.apply(.selectPreview(a), at: .zero)
        #expect(sw.preview == a && sw.program == a)
    }

    @Test func selectPreviewDuringTransitionIsIgnored() {
        var sw = makeSwitcher()
        _ = sw.apply(.fade(duration: 1), at: .zero)
        #expect(sw.apply(.selectPreview(c), at: time(0.5)).isEmpty)
        #expect(sw.preview == b)
        _ = sw.apply(.tbar(0), at: .zero)
        #expect(sw.tick(at: time(1)).last == .busesChanged(preview: a, program: b))
    }

    // MARK: Cut

    @Test func cutSwapsBuses() {
        var sw = makeSwitcher()
        #expect(sw.apply(.cut, at: .zero) == [.busesChanged(preview: a, program: b)])
        #expect(sw.program == b && sw.preview == a && sw.transition == .idle)
        _ = sw.apply(.cut, at: .zero)
        #expect(sw.program == a && sw.preview == b)
    }

    @Test func cutWithoutPreviewOrSameInputIsNoOp() {
        var empty = SwitcherState(preview: nil, program: a)
        #expect(empty.apply(.cut, at: .zero).isEmpty)
        #expect(empty.program == a)
        var same = SwitcherState(preview: a, program: a)
        #expect(same.apply(.cut, at: .zero).isEmpty)
    }

    @Test func cutToEmptyProgramIsAllowed() {
        var sw = SwitcherState(preview: b, program: nil)
        #expect(sw.apply(.cut, at: .zero) == [.busesChanged(preview: nil, program: b)])
    }

    @Test func cutDuringFadeCompletesImmediately() {
        var sw = makeSwitcher()
        _ = sw.apply(.fade(duration: 2), at: .zero)
        _ = sw.tick(at: time(0.5))
        #expect(sw.apply(.cut, at: time(0.6)) ==
                [.transitionProgress(1), .transitionCompleted, .busesChanged(preview: a, program: b)])
        #expect(sw.transition == .idle && sw.program == b)
        #expect(sw.tick(at: time(1)).isEmpty)
        #expect(!sw.tbarNeedsRearm)
    }

    // MARK: Fade temporizado

    @Test func fadeStartsAndEmitsStartEffects() {
        var sw = makeSwitcher()
        let effects = sw.apply(.fade(duration: 1), at: time(10))
        #expect(effects == [.transitionStarted(kind: .fade, from: a, to: b, duration: 1), .transitionProgress(0)])
        #expect(sw.transition == .running(kind: .fade, progress: 0))
        #expect(sw.program == a && sw.preview == b)
    }

    @Test func fadeProgressIsLinearInTime() {
        var sw = makeSwitcher()
        _ = sw.apply(.fade(duration: 2), at: time(10))
        #expect(sw.tick(at: time(10.5)) == [.transitionProgress(0.25)])
        #expect(sw.tick(at: time(11)) == [.transitionProgress(0.5)])
        #expect(sw.transition == .running(kind: .fade, progress: 0.5))
    }

    @Test func fadeCompletesAndSwaps() {
        var sw = makeSwitcher()
        _ = sw.apply(.fade(duration: 1), at: .zero)
        #expect(sw.tick(at: time(1.2)) ==
                [.transitionProgress(1), .transitionCompleted, .busesChanged(preview: a, program: b)])
        #expect(sw.transition == .idle && sw.program == b && sw.preview == a)
        #expect(!sw.tbarNeedsRearm)
    }

    @Test func fadeFullCycleAtFrameRate() {
        var sw = makeSwitcher()
        _ = sw.apply(.fade(duration: 0.5), at: .zero)
        var completed = 0, progresses: [Double] = []
        for frame in 1...40 {
            for effect in sw.tick(at: time(Double(frame) / 60)) {
                if case .transitionProgress(let p) = effect { progresses.append(p) }
                if effect == .transitionCompleted { completed += 1 }
            }
        }
        #expect(completed == 1)
        #expect(progresses == progresses.sorted() && progresses.last == 1)
    }

    @Test(arguments: [(0.01, 0.1), (0.1, 0.1), (3, 3), (5, 5), (60, 5), (-2, 0.1)])
    func fadeDurationIsClamped(requested: Double, effective: Double) {
        var sw = makeSwitcher()
        let effects = sw.apply(.fade(duration: requested), at: .zero)
        #expect(effects.first == .transitionStarted(kind: .fade, from: a, to: b, duration: effective))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteFadeIsIgnored(duration: Double) {
        var sw = makeSwitcher()
        #expect(sw.apply(.fade(duration: duration), at: .zero).isEmpty)
        #expect(sw.transition == .idle)
    }

    @Test func fadeWithoutPreviewOrSameInputIsNoOp() {
        var empty = SwitcherState(preview: nil, program: a)
        #expect(empty.apply(.fade(duration: 1), at: .zero).isEmpty)
        var same = SwitcherState(preview: a, program: a)
        #expect(same.apply(.fade(duration: 1), at: .zero).isEmpty)
        #expect(same.transition == .idle)
    }

    @Test func fadeDuringFadeIsIgnored() {
        var sw = makeSwitcher()
        _ = sw.apply(.fade(duration: 1), at: .zero)
        #expect(sw.apply(.fade(duration: 5), at: time(0.5)).isEmpty)
        #expect(sw.tick(at: time(1)).contains(.transitionCompleted))
    }

    @Test func tickWhileIdleOrBeforeStartIsSafe() {
        var sw = makeSwitcher()
        #expect(sw.tick(at: time(5)).isEmpty)
        _ = sw.apply(.fade(duration: 1), at: time(10))
        #expect(sw.tick(at: time(9)) == [.transitionProgress(0)])
    }

    // MARK: T-bar

    @Test func tbarStartsManualTransition() {
        var sw = makeSwitcher()
        #expect(sw.apply(.tbar(0.3), at: .zero) ==
                [.transitionStarted(kind: .fade, from: a, to: b, duration: nil), .transitionProgress(0.3)])
        #expect(sw.transition == .running(kind: .fade, progress: 0.3))
        #expect(sw.apply(.tbar(0.6), at: .zero) == [.transitionProgress(0.6)])
        #expect(sw.apply(.tbar(0.2), at: .zero) == [.transitionProgress(0.2)])
        #expect(sw.tick(at: time(100)).isEmpty, "La T-bar no avanza con el reloj")
    }

    @Test func tbarReachingOneCompletesAndSwaps() {
        var sw = makeSwitcher()
        _ = sw.apply(.tbar(0.5), at: .zero)
        #expect(sw.apply(.tbar(1), at: .zero) ==
                [.transitionProgress(1), .transitionCompleted, .busesChanged(preview: a, program: b)])
        #expect(sw.program == b && sw.preview == a && sw.transition == .idle)
        #expect(sw.tbarNeedsRearm)
    }

    @Test func tbarBackToZeroCancels() {
        var sw = makeSwitcher()
        _ = sw.apply(.tbar(0.5), at: .zero)
        #expect(sw.apply(.tbar(0), at: .zero) == [.transitionProgress(0), .transitionCompleted])
        #expect(sw.program == a && sw.preview == b && sw.transition == .idle)
        #expect(!sw.tbarNeedsRearm)
    }

    @Test func tbarAtZeroWhileIdleIsNoOp() {
        var sw = makeSwitcher()
        #expect(sw.apply(.tbar(0), at: .zero).isEmpty)
        #expect(sw.apply(.tbar(-3), at: .zero).isEmpty)
    }

    @Test func tbarJumpStraightToOneCompletesInOneCommand() {
        var sw = makeSwitcher()
        #expect(sw.apply(.tbar(1), at: .zero) == [
            .transitionStarted(kind: .fade, from: a, to: b, duration: nil),
            .transitionProgress(1), .transitionCompleted, .busesChanged(preview: a, program: b)
        ])
    }

    @Test func tbarOutOfRangeIsClamped() {
        var sw = makeSwitcher()
        _ = sw.apply(.tbar(0.4), at: .zero)
        #expect(sw.apply(.tbar(-0.5), at: .zero) == [.transitionProgress(0), .transitionCompleted])
        _ = sw.apply(.tbar(0.4), at: .zero)
        #expect(sw.apply(.tbar(7), at: .zero).contains(.transitionCompleted))
    }

    @Test func tbarNonFiniteIsIgnored() {
        var sw = makeSwitcher()
        _ = sw.apply(.tbar(0.4), at: .zero)
        #expect(sw.apply(.tbar(.nan), at: .zero).isEmpty)
        #expect(sw.apply(.tbar(.infinity), at: .zero).isEmpty)
        #expect(sw.transition == .running(kind: .fade, progress: 0.4))
    }

    @Test func tbarNeedsRearmAfterCompletion() {
        var sw = makeSwitcher()
        _ = sw.apply(.tbar(1), at: .zero)
        #expect(sw.apply(.tbar(1), at: .zero).isEmpty, "La palanca sigue arriba: no dispara otra")
        #expect(sw.apply(.tbar(0.5), at: .zero).isEmpty)
        #expect(sw.apply(.tbar(0), at: .zero).isEmpty)
        #expect(!sw.tbarNeedsRearm)
        #expect(sw.apply(.tbar(0.5), at: .zero).first == .transitionStarted(kind: .fade, from: b, to: a, duration: nil))
    }

    @Test func tbarWithoutPreviewIsNoOp() {
        var sw = SwitcherState(preview: nil, program: a)
        #expect(sw.apply(.tbar(0.5), at: .zero).isEmpty)
    }

    @Test func tbarDuringTimedFadeIsIgnored() {
        var sw = makeSwitcher()
        _ = sw.apply(.fade(duration: 1), at: .zero)
        _ = sw.tick(at: time(0.5))
        #expect(sw.apply(.tbar(0.9), at: time(0.5)).isEmpty)
        #expect(sw.apply(.tbar(0), at: time(0.5)).isEmpty)
        #expect(sw.transition == .running(kind: .fade, progress: 0.5))
    }

    @Test func fadeTakesOverManualTBar() {
        var sw = makeSwitcher()
        _ = sw.apply(.tbar(0.5), at: .zero)
        #expect(sw.apply(.fade(duration: 2), at: time(10)).isEmpty)
        // Resto (0,5) en 2 × 0,5 = 1 s.
        #expect(sw.tick(at: time(10.5)) == [.transitionProgress(0.75)])
        #expect(sw.apply(.tbar(0.1), at: time(10.5)).isEmpty, "Ya es temporizada")
        #expect(sw.tick(at: time(11)).last == .busesChanged(preview: a, program: b))
        #expect(sw.tbarNeedsRearm, "La palanca quedó a medias")
    }

    @Test func cutDuringManualTBarCompletesAndRequiresRearm() {
        var sw = makeSwitcher()
        _ = sw.apply(.tbar(0.7), at: .zero)
        #expect(sw.apply(.cut, at: .zero).last == .busesChanged(preview: a, program: b))
        #expect(sw.tbarNeedsRearm)
        #expect(sw.apply(.tbar(0.8), at: .zero).isEmpty)
    }

    @Test func otherTransitionsWorkWhileTBarNeedsRearm() {
        var sw = makeSwitcher()
        _ = sw.apply(.tbar(1), at: .zero)
        #expect(sw.apply(.cut, at: .zero) == [.busesChanged(preview: b, program: a)])
        #expect(sw.apply(.fade(duration: 1), at: .zero).count == 2)
    }

    // MARK: Reenvío

    @Test func nonBusCommandsAreForwarded() {
        var sw = makeSwitcher()
        let commands: [Command] = [
            .play(a), .pause(a), .restart(a), .seek(a, seconds: 2), .setLoop(a, true),
            .setVolume(a, 0.5), .setMute(a, true), .setSolo(a, true), .setAudioFollowsProgram(a, false),
            .setMasterVolume(0.8), .playlistNext(a), .playlistPrevious(a), .playlistJump(a, ItemID())
        ]
        for cmd in commands {
            #expect(sw.apply(cmd, at: .zero) == [.forward(cmd)])
        }
        #expect(sw.preview == b && sw.program == a)
    }

    @Test func forwardingDoesNotDisturbRunningTransition() {
        var sw = makeSwitcher()
        _ = sw.apply(.fade(duration: 1), at: .zero)
        #expect(sw.apply(.play(c), at: time(0.2)) == [.forward(.play(c))])
        #expect(sw.tick(at: time(0.5)) == [.transitionProgress(0.5)])
    }
}
