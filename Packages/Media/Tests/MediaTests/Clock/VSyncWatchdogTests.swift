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

/// Temporizador falso: solo registra arranques y paradas.
final class FakeTimerDriver: TickDriver {
    let starts = LockedState(0)
    let running = LockedState(false)
    var firesOffGrid: Bool { false }
    func start(_ onFire: @escaping @Sendable (Int64) -> Int64) {
        starts.withLock { $0 += 1 }
        running.withLock { $0 = true }
    }
    func stop() { running.withLock { $0 = false } }
}

/// Vigilancia del vsync con tiempo controlado por el test (determinista en VMs lentas).
@Suite struct VSyncWatchdogTests {
    let time = LockedState<Int64>(1_000_000_000)
    let vsync = FakeVSync()
    let timer = FakeTimerDriver()
    let fires = LockedState(0)
    let driver: VSyncTickDriver
    static let frame: Int64 = 16_666_667

    init() {
        let time = self.time
        driver = VSyncTickDriver(vsync: vsync, fallback: timer, initialGraceNanos: 100_000_000,
                                 recoveryPulses: 3, watchdogInterval: nil, now: { time.current })
    }

    private func advance(_ nanos: Int64) { time.withLock { $0 += nanos } }

    private func pulses(_ count: Int, every interval: Int64 = frame) {
        for _ in 0..<count {
            advance(interval)
            vsync.step()
            driver.checkStall()
        }
    }

    private func start() {
        let fires = self.fires
        driver.start { now in
            fires.withLock { $0 += 1 }
            return now + Self.frame
        }
    }

    @Test func fallsBackAfterThreeMissedRefreshesAndRecoversWithHysteresis() {
        start()
        pulses(15)
        #expect(!driver.isUsingFallback && fires.current == 15)

        // Corte de > 3 refrescos: entra el temporizador (una sola vez).
        advance(60_000_000)
        driver.checkStall()
        #expect(driver.isUsingFallback && driver.fallbackStarts == 1 && timer.running.current)
        driver.checkStall()
        #expect(driver.fallbackStarts == 1)

        // Dos pulsos no bastan (histéresis); al tercero vuelve el vsync.
        pulses(2)
        #expect(driver.isUsingFallback && timer.running.current)
        #expect(fires.current == 15) // con el temporizador al mando, los pulsos no disparan
        pulses(1)
        #expect(!driver.isUsingFallback && !timer.running.current)
        #expect(fires.current == 16)
        driver.stop()
    }

    /// Un vsync irregular (pulsos separados por más de 3 refrescos) no hace oscilar.
    @Test func irregularVSyncDoesNotOscillate() {
        start()
        pulses(5)
        advance(60_000_000)
        driver.checkStall()
        #expect(driver.fallbackStarts == 1)
        for _ in 0..<10 { pulses(1, every: 70_000_000) }
        #expect(driver.isUsingFallback)
        #expect(driver.fallbackStarts == 1)
        driver.stop()
    }

    @Test func screenChangeReinstallsVSync() {
        start()
        advance(200_000_000) // sin pulsos tras la gracia inicial: sin pantalla
        driver.checkStall()
        #expect(driver.isUsingFallback)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(vsync.starts.current == 2)
        pulses(3)
        #expect(!driver.isUsingFallback)
        driver.stop()
    }

    /// Dentro de la gracia inicial no se cae al temporizador.
    @Test func initialGraceIsRespected() {
        start()
        advance(90_000_000)
        driver.checkStall()
        #expect(!driver.isUsingFallback)
        advance(70_000_000)
        driver.checkStall()
        #expect(driver.isUsingFallback)
        driver.stop()
    }
}

extension MediaSerialTests {
    /// Integración con el reloj real: sin pulsos, el `MasterClock` sigue con el temporizador.
    @Suite(.timeLimit(.minutes(1)))
    struct VSyncFallbackClockTests {
        @Test func noDisplayStartsOnTimer() async {
            let driver = VSyncTickDriver(vsync: FakeVSync(), initialGraceNanos: 50_000_000)
            let clock = MasterClock(frameRate: .fps60, driver: driver, tickSource: .displayLink)
            clock.start()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !(driver.isUsingFallback && clock.stats.emittedTicks >= 3) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(driver.isUsingFallback)
            #expect(clock.stats.emittedTicks >= 3)
            clock.stop()
        }
    }
}
