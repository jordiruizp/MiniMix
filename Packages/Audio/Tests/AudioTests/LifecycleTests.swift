import Core
import CoreMocks
import Testing
@testable import Audio

/// Rearranque tras un cambio de configuración de la salida.
@Suite struct LifecycleTests {
    @Test func restartsAfterConfigurationChangeAndReportsIt() async throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        try engine.start()

        engine.simulateSystemStop()
        #expect(!engine.isRunning)
        engine.handleConfigurationChange()
        engine.drainLifecycleQueue()

        let received = await collectEvents(engine, count: 2)
        #expect(received == [.configurationChanged, .restarted])
        #expect(engine.isRunning)
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.5) < 1e-3)
    }

    @Test func doesNotRestartAfterExplicitStop() async throws {
        let engine = try makeOfflineEngine()
        try engine.start()
        engine.stop()
        engine.handleConfigurationChange()
        engine.drainLifecycleQueue()
        #expect(await collectEvents(engine, count: 2, timeout: 0.2) == [.configurationChanged])
        #expect(!engine.isRunning)
    }
}

/// Lee hasta `count` eventos ya publicados; se rinde a los `timeout` segundos (no se cuelga si
/// falta alguno).
func collectEvents(_ engine: AudioEngine, count: Int, timeout: Double = 1) async -> [AudioEngineEvent] {
    let received = Locked<[AudioEngineEvent]>([])
    let reader = Task {
        for await event in engine.events {
            let total = received.withLock { list -> Int in
                list.append(event)
                return list.count
            }
            if total >= count { return }
        }
    }
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(timeout))
        reader.cancel()
    }
    await reader.value
    watchdog.cancel()
    return received.current
}
