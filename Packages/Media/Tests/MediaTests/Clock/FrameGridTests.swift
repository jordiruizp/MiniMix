import Core
import Foundation
import Testing
@testable import Media

@Suite struct FrameGridTests {
    static let rates: [FrameRate] = [FrameRate(24000, 1001), .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60]

    @Test(arguments: rates)
    func indexAndStartAreInverse(rate: FrameRate) {
        let grid = FrameGrid(rate: rate, anchorNanos: 123_456_789_012)
        for n: Int64 in [0, 1, 2, 999, 1_001, 60_000, 3_600_000, 100_000_000] {
            let start = grid.startNanos(ofIndex: n)
            #expect(grid.index(atNanos: start) == n)
            #expect(grid.index(atNanos: start - 1) == n - 1)
        }
    }

    /// Sin acumulación: el fotograma n está a n·den/num s del ancla (± 1 ns),
    /// incluso tras 10⁸ fotogramas (~19 días a 59,94).
    @Test(arguments: rates)
    func noAccumulatedError(rate: FrameRate) {
        let grid = FrameGrid(rate: rate, anchorNanos: 0)
        for n: Int64 in [1, 1_000, 1_000_000, 100_000_000] {
            let exact = Double(n) * Double(rate.denominator) * 1e9 / Double(rate.numerator)
            #expect(abs(Double(grid.startNanos(ofIndex: n)) - exact) <= 1.0)
        }
    }

    @Test func negativeTimesFloor() {
        let grid = FrameGrid(rate: .fps25, anchorNanos: 1_000_000_000)
        #expect(grid.index(atNanos: 999_999_999) == -1)
        #expect(grid.index(atNanos: 1_000_000_000 - 40_000_000) == -1)
        #expect(grid.index(atNanos: 1_000_000_000 - 40_000_001) == -2)
    }

    /// `DispatchTime` (que usa el temporizador) y el reloj del host comparten base.
    @Test func hostClockMatchesDispatchTime() {
        let host = HostClock.nowNanos()
        let dispatch = Int64(DispatchTime.now().uptimeNanoseconds)
        #expect(abs(dispatch - host) < 1_000_000)
    }

    @Test func hostTimeRoundTrip() {
        let nanos: Int64 = 987_654_321_123_456
        let time = HostClock.hostTime(nanos: nanos)
        #expect(abs(HostClock.nanos(time) - nanos) <= 1)
    }
}
