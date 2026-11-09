import Core
import Foundation
import Testing
@testable import Media

/// Tasa de ticks saltados del `MasterClock` en reposo (T90: 0 en 30 min).
extension MediaSerialTests {
    @Suite struct ClockSkipTests {
        struct SkipReport {
            var seconds: Double
            var emitted: Int
            var skipped: Int
            var maxGapMs: Double
        }

        /// Consume los ticks como el render (bufferingNewest(1)) y mide saltos y hueco máximo.
        static func soak(_ clock: MasterClock, seconds: Double) async -> SkipReport {
            let stream = clock.ticks
            clock.start()
            let consumer = Task {
                var last: Double?
                var maxGap = 0.0
                for await tick in stream {
                    if let last { maxGap = max(maxGap, tick.seconds - last) }
                    last = tick.seconds
                }
                return maxGap
            }
            try? await Task.sleep(for: .seconds(seconds))
            clock.stop()
            let maxGap = await consumer.value
            return SkipReport(seconds: seconds, emitted: clock.stats.emittedTicks, skipped: clock.stats.skippedTicks,
                              maxGapMs: maxGap * 1000)
        }

        static func describe(_ label: String, _ r: SkipReport) -> String {
            String(format: "[T30] %@: %.0f s · emitidos %d · saltados %d (%.4f %%) · hueco máx %.1f ms",
                   label, r.seconds, r.emitted, r.skipped, Double(r.skipped) / Double(max(r.emitted, 1)) * 100, r.maxGapMs)
        }

        static var soakSeconds: Double? {
            ProcessInfo.processInfo.environment["MINIMIX_CLOCK_SOAK"].flatMap(Double.init)
        }

        /// Corto (siempre): 10 s con el driver por defecto.
        @Test(.timeLimit(.minutes(1)))
        func shortSkipRate() async {
            let clock = MasterClock(frameRate: .fps60)
            let report = await Self.soak(clock, seconds: 10)
            print(Self.describe("tasa de saltos (\(clock.tickSource))", report))
            PerfGate.check(report.skipped == 0, "ticks saltados en 10 s: \(report.skipped)")
        }

        /// Largo (MINIMIX_LONG_TESTS=1): 30 min en reposo con el driver por defecto, 0 saltados.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["MINIMIX_LONG_TESTS"] == "1"),
              .timeLimit(.minutes(35)))
        func thirtyMinutesWithoutSkips() async {
            let clock = MasterClock(frameRate: .fps60)
            let report = await Self.soak(clock, seconds: 1_800)
            print(Self.describe("30 min (\(clock.tickSource))", report))
            PerfGate.check(report.skipped == 0, "ticks saltados en 30 min: \(report.skipped)")
        }

        /// Diagnóstico (MINIMIX_CLOCK_SOAK=segundos): compara los drivers.
        @Test(.enabled(if: soakSeconds != nil), .timeLimit(.minutes(130)))
        func compareDrivers() async {
            let seconds = Self.soakSeconds ?? 0
            for source in [MasterClock.TickSource.displayLink, .timer] {
                let report = await Self.soak(MasterClock(frameRate: .fps60, tickSource: source), seconds: seconds)
                print(Self.describe("\(source)", report))
            }
        }
    }
}
