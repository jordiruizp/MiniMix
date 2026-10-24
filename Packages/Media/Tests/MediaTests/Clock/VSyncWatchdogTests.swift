import AppKit
import Core
import Foundation
import Testing
@testable import Media

/// Vsync falso: los pulsos los da el test.
final class FakeVSync: VSyncSource {
    let starts = LockedState(0)
    private let handler = LockedState<(@Sendable () -> Void)?>(nil)
    var frameNanos: Int64 { 16_666_667 }

    func start(_ onStep: @escaping @Sendable () -> Void) {
        starts.withLock { $0 += 1 }
        handler.withLock { $0 = onStep }
    }

    func stop() { handler.withLock { $0 = nil } }
    func step() { handler.current?() }
}

extension MediaSerialTests {
    @Suite(.timeLimit(.minutes(1)))
    struct VSyncWatchdogTests {
        private func pulse(_ vsync: FakeVSync, count: Int) async {
            for _ in 0..<count {
                vsync.step()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }

        @Test func fallsBackToTimerAndRecovers() async {
            let vsync = FakeVSync()
            let driver = VSyncTickDriver(vsync: vsync, initialGraceNanos: 100_000_000)
            let clock = MasterClock(frameRate: .fps60, driver: driver, tickSource: .displayLink)
            clock.start()
            await pulse(vsync, count: 15)
            #expect(!driver.isUsingFallback)
            let viaVSync = clock.stats.emittedTicks
            #expect(viaVSync >= 10)

            // El vsync se detiene: tras > 3 refrescos el temporizador toma el relevo.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(driver.isUsingFallback)
            #expect(driver.fallbackStarts == 1)
            let duringStall = clock.stats.emittedTicks - viaVSync
            PerfGate.check(duringStall >= 10, "ticks del temporizador durante el corte: \(duringStall)")
            #expect(duringStall >= 3)

            // Vuelve un pulso: se abandona el temporizador.
            await pulse(vsync, count: 3)
            #expect(!driver.isUsingFallback)

            // Nuevo corte y cambio de pantallas: se reinstala el vsync.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(driver.isUsingFallback)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(vsync.starts.current == 2)
            await pulse(vsync, count: 3)
            #expect(!driver.isUsingFallback)
            clock.stop()
        }

        /// Sin ningún pulso (sin pantalla) el reloj arranca con el temporizador tras la gracia inicial.
        @Test func noDisplayStartsOnTimer() async {
            let vsync = FakeVSync()
            let driver = VSyncTickDriver(vsync: vsync, initialGraceNanos: 50_000_000)
            let clock = MasterClock(frameRate: .fps60, driver: driver, tickSource: .displayLink)
            clock.start()
            try? await Task.sleep(for: .milliseconds(400))
            #expect(driver.isUsingFallback)
            #expect(clock.stats.emittedTicks >= 3)
            clock.stop()
        }
    }
}
