import Testing
@testable import Media

@Suite struct RetirementQueueTests {
    @Test func keepsAtLeastMinCount() {
        var queue = RetirementQueue<Int>(minCount: 3, minAgeNanos: 200)
        for i in 0..<10 { queue.retire(i, now: Int64(i) * 1_000) }
        #expect(queue.items.map(\.element) == [7, 8, 9])
    }

    /// Render rápido: muchos fotogramas en menos de 200 ms → no se suelta ninguno.
    @Test func keepsEverythingYoungerThanMinAge() {
        var queue = RetirementQueue<Int>(minCount: 3, minAgeNanos: 200_000_000)
        for i in 0..<12 { queue.retire(i, now: Int64(i) * 16_666_667) } // 12 fotogramas a 60 Hz ≈ 183 ms
        #expect(queue.count == 12)
        queue.retire(12, now: 210_000_000)
        #expect(queue.items.first?.element == 1)
        #expect(queue.items.dropFirst().allSatisfy { 210_000_000 - $0.retiredAt < 200_000_000 })
    }
}
