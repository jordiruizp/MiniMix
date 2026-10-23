import Core
import Foundation
import Testing

private func item(enabled: Bool = true, stopAfter: Bool = false) -> PlaylistItem {
    PlaylistItem(source: .color(.black), duration: 1, stopAfter: stopAfter, enabled: enabled)
}

private func sequencer(_ items: [PlaylistItem], mode: PlaybackMode = .continuous, loop: Bool = false) -> PlaylistSequencer {
    PlaylistSequencer(playlist: Playlist(items: items, mode: mode, loop: loop))
}

private func items(_ count: Int) -> [PlaylistItem] { (0..<count).map { _ in item() } }

@Suite("T12 · PlaylistSequencer")
struct PlaylistSequencerTests {
    // MARK: Modo continuo

    @Test func startsIdleAndPlaysFirst() {
        var seq = sequencer(items(3))
        #expect(seq.state == .idle && seq.upcomingIndex == 0 && seq.currentIndex == nil && seq.currentItem == nil)
        #expect(seq.handle(.play) == .playing(index: 0))
        #expect(seq.currentItem == seq.playlist.items[0])
        #expect(seq.upcomingIndex == 1)
    }

    @Test func continuousPlaysThroughAndEnds() {
        var seq = sequencer(items(3))
        seq.handle(.play)
        #expect(seq.handle(.itemEnded) == .playing(index: 1))
        #expect(seq.handle(.itemEnded) == .playing(index: 2))
        #expect(seq.upcomingIndex == nil)
        #expect(seq.handle(.itemEnded) == .ended)
        #expect(seq.upcomingIndex == 0)
        #expect(seq.handle(.play) == .playing(index: 0))
    }

    @Test func continuousLoopWrapsAround() {
        var seq = sequencer(items(2), loop: true)
        seq.handle(.play)
        seq.handle(.itemEnded)
        #expect(seq.upcomingIndex == 0)
        #expect(seq.handle(.itemEnded) == .playing(index: 0))
    }

    @Test func singleItemLoopRepeatsItself() {
        var seq = sequencer(items(1), loop: true)
        seq.handle(.play)
        #expect(seq.upcomingIndex == 0)
        #expect(seq.handle(.itemEnded) == .playing(index: 0))
    }

    @Test func playWhilePlayingIsNoOp() {
        var seq = sequencer(items(3))
        seq.handle(.play)
        seq.handle(.next)
        #expect(seq.handle(.play) == .playing(index: 1))
    }

    @Test func itemEndedOutsidePlayingIsIgnored() {
        var seq = sequencer(items(2), mode: .stopAfterEach)
        #expect(seq.handle(.itemEnded) == .idle)
        seq.handle(.play)
        seq.handle(.itemEnded)
        #expect(seq.handle(.itemEnded) == .held(index: 0, cued: 1))
    }

    // MARK: Parar tras cada / stopAfter

    @Test func stopAfterEachHoldsAndResumes() {
        var seq = sequencer(items(3), mode: .stopAfterEach)
        seq.handle(.play)
        #expect(seq.handle(.itemEnded) == .held(index: 0, cued: 1))
        #expect(seq.upcomingIndex == 1 && seq.currentIndex == 0)
        #expect(seq.handle(.play) == .playing(index: 1))
        seq.handle(.itemEnded)
        seq.handle(.play)
        #expect(seq.handle(.itemEnded) == .held(index: 2, cued: nil))
        #expect(seq.handle(.play) == .ended)
    }

    @Test func stopAfterEachWithLoopCuesFirst() {
        var seq = sequencer(items(2), mode: .stopAfterEach, loop: true)
        seq.handle(.jump(seq.playlist.items[1].id))
        #expect(seq.handle(.itemEnded) == .held(index: 1, cued: 0))
        #expect(seq.handle(.play) == .playing(index: 0))
    }

    @Test func itemStopAfterHoldsInContinuousMode() {
        var seq = sequencer([item(), item(stopAfter: true), item()])
        seq.handle(.play)
        seq.handle(.itemEnded)
        #expect(seq.upcomingIndex == 2)
        #expect(seq.handle(.itemEnded) == .held(index: 1, cued: 2))
        #expect(seq.handle(.play) == .playing(index: 2))
        #expect(seq.handle(.itemEnded) == .ended)
    }

    // MARK: Vacía y deshabilitados

    @Test func emptyPlaylist() {
        var seq = sequencer([])
        #expect(seq.upcomingIndex == nil)
        #expect(seq.handle(.play) == .ended)
        #expect(seq.handle(.next) == .ended)
        #expect(seq.handle(.previous) == .ended)
        #expect(seq.handle(.restartItem) == .ended)
        #expect(seq.handle(.jump(ItemID())) == .ended)
        #expect(seq.handle(.itemEnded) == .ended)
    }

    @Test func allDisabled() {
        var seq = sequencer([item(enabled: false), item(enabled: false)], loop: true)
        #expect(seq.upcomingIndex == nil)
        #expect(seq.handle(.play) == .ended)
        #expect(seq.handle(.jump(seq.playlist.items[0].id)) == .ended)
    }

    @Test func disabledItemsAreSkippedButKeepNumbering() {
        var seq = sequencer([item(enabled: false), item(), item(enabled: false), item()])
        #expect(seq.handle(.play) == .playing(index: 1))
        #expect(seq.upcomingIndex == 3)
        #expect(seq.handle(.itemEnded) == .playing(index: 3))
        #expect(seq.handle(.previous) == .playing(index: 1))
        #expect(seq.handle(.itemEnded) == .playing(index: 3))
        #expect(seq.handle(.itemEnded) == .ended)
    }

    @Test func loopSkipsDisabledWhenWrapping() {
        var seq = sequencer([item(enabled: false), item(), item(), item(enabled: false)], loop: true)
        seq.handle(.jump(seq.playlist.items[2].id))
        #expect(seq.handle(.itemEnded) == .playing(index: 1))
        #expect(seq.handle(.previous) == .playing(index: 2))
    }

    // MARK: Saltos y navegación

    @Test func jumpToEnabledItemFromAnyState() {
        var seq = sequencer(items(3), mode: .stopAfterEach)
        let target = seq.playlist.items[2].id
        #expect(seq.handle(.jump(target)) == .playing(index: 2))
        seq.handle(.itemEnded)
        #expect(seq.handle(.jump(seq.playlist.items[0].id)) == .playing(index: 0))
        seq.handle(.jump(target))
        seq.handle(.itemEnded)
        seq.handle(.play)
        #expect(seq.state == .ended)
        #expect(seq.handle(.jump(target)) == .playing(index: 2))
    }

    @Test func jumpToDisabledOrMissingItemIsIgnored() {
        var seq = sequencer([item(), item(enabled: false)])
        seq.handle(.play)
        #expect(seq.handle(.jump(seq.playlist.items[1].id)) == .playing(index: 0))
        #expect(seq.handle(.jump(ItemID())) == .playing(index: 0))
    }

    @Test func nextAndPrevious() {
        var seq = sequencer(items(3))
        seq.handle(.play)
        #expect(seq.handle(.next) == .playing(index: 1))
        #expect(seq.handle(.next) == .playing(index: 2))
        #expect(seq.handle(.next) == .playing(index: 2), "Sin bucle, Next en el último no hace nada")
        #expect(seq.handle(.previous) == .playing(index: 1))
    }

    @Test func nextAndPreviousWithLoopWrap() {
        var seq = sequencer(items(3), loop: true)
        seq.handle(.play)
        #expect(seq.handle(.previous) == .playing(index: 2))
        #expect(seq.handle(.next) == .playing(index: 0))
    }

    @Test func previousOnFirstRestartsItem() {
        var seq = sequencer(items(3), mode: .stopAfterEach)
        seq.handle(.play)
        #expect(seq.handle(.previous) == .playing(index: 0))
        seq.handle(.itemEnded)
        #expect(seq.handle(.previous) == .playing(index: 0), "Desde held también reanuda el primero")
    }

    @Test func nextAndPreviousFromHeld() {
        var seq = sequencer(items(3), mode: .stopAfterEach)
        seq.handle(.next)
        #expect(seq.state == .playing(index: 0), "Next desde idle arranca el primero")
        seq.handle(.next)
        seq.handle(.itemEnded)
        #expect(seq.state == .held(index: 1, cued: 2))
        #expect(seq.handle(.next) == .playing(index: 2))
        seq.handle(.itemEnded)
        #expect(seq.handle(.next) == .held(index: 2, cued: nil), "Sin siguiente: sin cambio")
    }

    @Test func navigationFromIdleAndEnded() {
        var seq = sequencer(items(3))
        #expect(seq.handle(.previous) == .playing(index: 0))
        seq.handle(.jump(seq.playlist.items[2].id))
        seq.handle(.itemEnded)
        #expect(seq.state == .ended)
        #expect(seq.handle(.previous) == .playing(index: 2))
        seq.handle(.itemEnded)
        #expect(seq.handle(.next) == .playing(index: 0))
        var empty = sequencer([])
        empty.handle(.play)
        #expect(empty.handle(.previous) == .ended)
    }

    @Test func restartItemKeepsIndex() {
        var seq = sequencer(items(3), mode: .stopAfterEach)
        #expect(seq.handle(.restartItem) == .idle)
        seq.handle(.next)
        seq.handle(.next)
        #expect(seq.handle(.restartItem) == .playing(index: 1))
        seq.handle(.itemEnded)
        #expect(seq.handle(.restartItem) == .playing(index: 1))
    }

    @Test func restartSignal() {
        var seq = sequencer(items(3))
        seq.handle(.play)
        #expect(!seq.lastEventRestartsItem, "Empieza un item nuevo: el índice cambia")
        seq.handle(.previous)
        #expect(seq.lastEventRestartsItem, "previous en el primero sin bucle")
        seq.handle(.next)
        #expect(!seq.lastEventRestartsItem)
        seq.handle(.restartItem)
        #expect(seq.lastEventRestartsItem)
        seq.handle(.play)
        #expect(!seq.lastEventRestartsItem, "play mientras suena no hace nada")
        seq.handle(.next)
        seq.handle(.next)
        #expect(seq.state == .playing(index: 2) && !seq.lastEventRestartsItem, "next en el último sin bucle")
        seq.handle(.jump(seq.playlist.items[2].id))
        #expect(seq.lastEventRestartsItem, "jump al item que ya suena")
    }

    @Test func restartSignalForSingleItemLoop() {
        var seq = sequencer(items(1), loop: true)
        seq.handle(.play)
        #expect(seq.upcomingIndex == seq.currentIndex)
        seq.handle(.itemEnded)
        #expect(seq.state == .playing(index: 0) && seq.lastEventRestartsItem)
        var held = sequencer(items(1), mode: .stopAfterEach, loop: true)
        held.handle(.play)
        held.handle(.itemEnded)
        #expect(held.state == .held(index: 0, cued: 0) && !held.lastEventRestartsItem)
        held.handle(.play)
        #expect(held.lastEventRestartsItem)
    }

    // MARK: Edición mientras suena

    @Test func insertingBeforeCurrentShiftsIndex() {
        var seq = sequencer(items(3))
        seq.handle(.next)
        seq.handle(.next)
        let current = seq.playlist.items[1].id
        seq.playlist.items.insert(item(), at: 0)
        #expect(seq.state == .playing(index: 2))
        #expect(seq.currentItem?.id == current)
        #expect(seq.upcomingIndex == 3)
    }

    @Test func reorderingFollowsCurrentItem() {
        var seq = sequencer(items(3))
        seq.handle(.play)
        let current = seq.playlist.items[0].id
        seq.playlist.items.reverse()
        #expect(seq.state == .playing(index: 2))
        #expect(seq.currentItem?.id == current)
        #expect(seq.handle(.itemEnded) == .ended)
    }

    @Test func removingCurrentItemMovesToSuccessor() {
        var seq = sequencer(items(3))
        seq.handle(.next)
        seq.handle(.next)
        seq.playlist.items.remove(at: 1)
        #expect(seq.state == .playing(index: 1), "El que ocupaba su lugar")
        seq.playlist.items.remove(at: 1)
        #expect(seq.state == .ended)
    }

    @Test func removingCurrentAndEarlierItemsFollowsOldSuccessor() {
        var seq = sequencer(items(4))
        let ids = seq.playlist.items.map(\.id)
        seq.handle(.jump(ids[2]))
        seq.playlist.items.removeAll { $0.id == ids[0] || $0.id == ids[2] }
        #expect(seq.state == .playing(index: 1))
        #expect(seq.currentItem?.id == ids[3])
    }

    @Test func removingCurrentAndInsertingBeforeFollowsOldSuccessor() {
        var seq = sequencer(items(3))
        let ids = seq.playlist.items.map(\.id)
        seq.handle(.jump(ids[1]))
        var edited = seq.playlist
        edited.items.remove(at: 1)
        edited.items.insert(contentsOf: [item(), item()], at: 0)
        seq.playlist = edited
        #expect(seq.state == .playing(index: 3))
        #expect(seq.currentItem?.id == ids[2])
    }

    @Test func removedCurrentSkipsDisabledOldSuccessors() {
        var seq = sequencer([item(), item(), item(enabled: false), item()])
        let ids = seq.playlist.items.map(\.id)
        seq.handle(.jump(ids[1]))
        seq.playlist.items.remove(at: 1)
        #expect(seq.currentItem?.id == ids[3])
    }

    @Test func removingLastCurrentWithLoopWrapsToFirst() {
        var seq = sequencer(items(3), loop: true)
        seq.handle(.jump(seq.playlist.items[2].id))
        seq.playlist.items.removeLast()
        #expect(seq.state == .playing(index: 0))
    }

    @Test func removingHeldItemEnds() {
        var seq = sequencer(items(3), mode: .stopAfterEach)
        seq.handle(.play)
        seq.handle(.itemEnded)
        seq.playlist.items.remove(at: 0)
        #expect(seq.state == .ended)
    }

    @Test func editingWhileHeldRecomputesCue() {
        var seq = sequencer(items(3), mode: .stopAfterEach)
        seq.handle(.play)
        seq.handle(.itemEnded)
        #expect(seq.state == .held(index: 0, cued: 1))
        seq.playlist.items[1].enabled = false
        #expect(seq.state == .held(index: 0, cued: 2))
        seq.playlist.items[2].enabled = false
        #expect(seq.state == .held(index: 0, cued: nil))
        seq.playlist.loop = true
        #expect(seq.state == .held(index: 0, cued: 0))
    }

    @Test func disablingCurrentItemKeepsItPlaying() {
        var seq = sequencer(items(3))
        seq.handle(.next)
        seq.handle(.next)
        seq.playlist.items[1].enabled = false
        #expect(seq.state == .playing(index: 1))
        #expect(seq.upcomingIndex == 2)
        #expect(seq.handle(.previous) == .playing(index: 0))
    }

    @Test func changingModeAffectsNextItemEnd() {
        var seq = sequencer(items(3))
        seq.handle(.play)
        seq.playlist.mode = .stopAfterEach
        #expect(seq.handle(.itemEnded) == .held(index: 0, cued: 1))
    }

    @Test func editsWhileIdleOrEndedKeepState() {
        var seq = sequencer(items(1))
        seq.playlist.items.append(item())
        #expect(seq.state == .idle)
        seq.handle(.play)
        seq.handle(.next)
        seq.handle(.itemEnded)
        seq.playlist.items.removeAll()
        #expect(seq.state == .ended)
    }
}
