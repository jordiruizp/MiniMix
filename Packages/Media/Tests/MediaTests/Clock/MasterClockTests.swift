import Core
import Foundation
import Testing
@testable import Media

/// Resultado de observar los ticks de un reloj durante un intervalo.
struct ClockObservation {
    var ticks: [Double] = []
    /// `now` en el consumidor al recibir cada tick.
    var arrivals: [Double] = []

    /// Desfase (llegada − tiempo del fotograma) en ms.
    var lateness: [Double] { zip(arrivals, ticks).map { ($0 - $1) * 1000 } }

    /// Deriva en ms/min: mediana del desfase en la última ventana menos la de la
    /// primera, escalada a un minuto.
    func driftPerMinute(window: Double = 2) -> Double {
        guard let first = ticks.first, let last = ticks.last, last - first > 2 * window else { return .infinity }
        let late = lateness
        let head = zip(ticks, late).filter { $0.0 < first + window }.map(\.1)
        let tail = zip(ticks, late).filter { $0.0 > last - window }.map(\.1)
        return abs(median(tail) - median(head)) * 60 / (last - first)
    }

    /// Máximo error (en fotogramas) de cualquier tick respecto a la rejilla t0 + n·Δ.
    func maxGridError(_ rate: FrameRate) -> Double {
        guard let first = ticks.first else { return .infinity }
        return ticks.map { t in
            let frames = (t - first) * rate.fps
            return abs(frames - frames.rounded())
        }.max() ?? 0
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
    }
}

func observe(_ clock: MasterClock, seconds: Double) async -> ClockObservation {
    let stream = clock.ticks
    clock.start()
    let collector = Task {
        var result = ClockObservation()
        for await tick in stream {
            result.arrivals.append(clock.now.seconds)
            result.ticks.append(tick.seconds)
        }
        return result
    }
    try? await Task.sleep(for: .seconds(seconds))
    clock.stop()
    return await collector.value
}

extension MediaSerialTests {
    @Suite struct MasterClockTests {
        @Test func nowIsMonotonicHostTime() {
            let clock = MasterClock(tickSource: .timer)
            let a = clock.now
            let b = clock.now
            #expect(b >= a)
            #expect(abs(a.seconds - Double(DispatchTime.now().uptimeNanoseconds) / 1e9) < 0.01)
        }

        @Test(arguments: [FrameRate.fps25, .fps29_97, .fps59_94])
        func ticksLieOnTheFrameGrid(rate: FrameRate) async {
            let clock = MasterClock(frameRate: rate, tickSource: .timer)
            let obs = await observe(clock, seconds: 1)
            #expect(clock.stats.emittedTicks + clock.stats.skippedTicks >= Int(rate.fps * 0.9))
            #expect(!obs.ticks.isEmpty)
            #expect(obs.maxGridError(rate) < 1e-5)
            #expect(zip(obs.ticks, obs.ticks.dropFirst()).allSatisfy { $0 < $1 })
            // Un tick nunca está en el futuro.
            #expect(zip(obs.ticks, obs.arrivals).allSatisfy { $0 <= $1 })
        }

        @Test func hotFrameRateChange() async {
            let clock = MasterClock(frameRate: .fps25, tickSource: .timer)
            let stream = clock.ticks
            clock.start()
            let collector = Task {
                var ticks: [Double] = []
                for await tick in stream { ticks.append(tick.seconds) }
                return ticks
            }
            try? await Task.sleep(for: .milliseconds(600))
            clock.setFrameRate(.fps60)
            #expect(clock.frameRate == .fps60)
            try? await Task.sleep(for: .milliseconds(600))
            clock.stop()
            let ticks = await collector.value
            let deltas = zip(ticks, ticks.dropFirst()).map { ($1 - $0) * 1000 }
            #expect(deltas.allSatisfy { $0 > 0 })
            // Antes del cambio, múltiplos de 40 ms; después, de 16,67 ms.
            let multipleOf = { (d: Double, step: Double) in abs(d / step - (d / step).rounded()) < 1e-3 }
            #expect(deltas.prefix(5).allSatisfy { multipleOf($0, 40) })
            #expect(deltas.suffix(10).allSatisfy { multipleOf($0, 1000.0 / 60) })
            #expect(deltas.contains { abs($0 - 1000.0 / 60) < 0.01 })
        }

        @Test func multicastAndRestart() async {
            let clock = MasterClock(frameRate: .fps60, tickSource: .timer)
            let s1 = clock.ticks
            let s2 = clock.ticks
            clock.start()
            async let a = s1.prefix(5).reduce(0) { n, _ in n + 1 }
            async let b = s2.prefix(5).reduce(0) { n, _ in n + 1 }
            let (ca, cb) = await (a, b)
            #expect(ca == 5 && cb == 5)
            clock.stop()
            #expect(!clock.isRunning)
            let s3 = clock.ticks
            clock.start()
            let c = await s3.prefix(3).reduce(0) { n, _ in n + 1 }
            #expect(c == 3)
            clock.stop()
        }

        /// Aceptación T30 (corta, siempre): 20 s a 59,94, deriva extrapolada < 1 ms/min.
        @Test(.timeLimit(.minutes(1)))
        func driftShort() async {
            let rate = FrameRate.fps59_94
            let clock = MasterClock(frameRate: rate, tickSource: .timer)
            let obs = await observe(clock, seconds: 20)
            let drift = obs.driftPerMinute()
            let late = obs.lateness.sorted()
            print("""
                [T30] deriva 20 s @59,94: \(String(format: "%.4f", drift)) ms/min · ticks \(obs.ticks.count) · \
                saltados \(clock.stats.skippedTicks) · desfase p50 \(String(format: "%.3f", late[late.count / 2])) ms \
                p99 \(String(format: "%.3f", late[late.count * 99 / 100])) ms · error rejilla \(obs.maxGridError(rate)) fot.
                """)
            #expect(drift < 1)
            #expect(obs.maxGridError(rate) < 1e-5)
            // Ticks recibidos + saltados ≈ fotogramas transcurridos.
            let elapsedFrames = ((obs.ticks.last ?? 0) - (obs.ticks.first ?? 0)) * rate.fps
            #expect(abs(Double(clock.stats.emittedTicks + clock.stats.skippedTicks - 1) - elapsedFrames) <= 2)
        }

        /// Aceptación T30 (larga): 10 min. Solo con `MINIMIX_LONG_TESTS=1`.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["MINIMIX_LONG_TESTS"] == "1"),
              .timeLimit(.minutes(12)))
        func driftTenMinutes() async {
            let rate = FrameRate.fps59_94
            let clock = MasterClock(frameRate: rate, tickSource: .timer)
            let obs = await observe(clock, seconds: 600)
            let drift = obs.driftPerMinute(window: 10)
            print("[T30] deriva 10 min @59,94: \(String(format: "%.4f", drift)) ms/min · ticks \(obs.ticks.count) · "
                  + "saltados \(clock.stats.skippedTicks) · error rejilla \(obs.maxGridError(rate)) fot.")
            #expect(drift < 1)
            #expect(obs.maxGridError(rate) < 1e-5)
        }

        /// Con pantalla, el driver de `CADisplayLink` produce ticks en la rejilla.
        @Test(.enabled(if: DisplayLinkTickDriver.hasDisplay), .timeLimit(.minutes(1)))
        func displayLinkTicks() async {
            let clock = MasterClock(frameRate: .fps30, tickSource: .displayLink)
            #expect(clock.tickSource == .displayLink)
            let obs = await observe(clock, seconds: 1.5)
            print("[T30] displayLink: \(obs.ticks.count) ticks en 1,5 s @30")
            #expect(obs.ticks.count >= 20)
            #expect(obs.maxGridError(.fps30) < 1e-5)
        }
    }
}
