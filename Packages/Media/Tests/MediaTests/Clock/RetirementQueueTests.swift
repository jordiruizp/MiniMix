import Testing
@testable import Media

@Suite struct RetirementQueueTests {
    @Test func keepsAtLeastMinCountWhileRetiring() {
        var queue = RetirementQueue<Int>(minCount: 3, maxCount: 6, minAgeNanos: 200)
        for i in 0..<10 { queue.retire(i, now: Int64(i) * 1_000) }
        #expect(queue.items.map(\.element) == [7, 8, 9])
    }

    /// Render rápido (60 Hz): la edad mínima de 100 ms retendría 6; el tope duro es 6.
    @Test func hardCapBoundsMemory() {
        var queue = RetirementQueue<Int>()
        for i in 0..<60 { queue.retire(i, now: Int64(i) * 2_000_000) } // 500 Hz: todos «jóvenes»
        #expect(queue.count == 6)
        #expect(queue.items.first?.element == 54)
    }

    @Test func youngFramesSurviveUpToCap() {
        var queue = RetirementQueue<Int>()
        for i in 0..<5 { queue.retire(i, now: Int64(i) * 16_666_667) } // 67 ms
        #expect(queue.count == 5)
    }

    /// Sin fotogramas nuevos (pausa visible) la poda por edad lo suelta todo.
    @Test func pruneDropsEverythingOldEnough() {
        var queue = RetirementQueue<Int>()
        for i in 0..<4 { queue.retire(i, now: Int64(i) * 16_666_667) }
        queue.prune(now: 120_000_000)
        #expect(queue.items.map(\.element) == [2, 3])
        queue.prune(now: 200_000_000)
        #expect(queue.items.isEmpty)
    }
}
