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

        var iterator = engine.events.makeAsyncIterator()
        #expect(await iterator.next() == .configurationChanged)
        #expect(await iterator.next() == .restarted)
        #expect(engine.isRunning)
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.5) < 1e-3)
    }

    @Test func doesNotRestartAfterExplicitStop() async throws {
        let engine = try makeOfflineEngine()
        try engine.start()
        engine.stop()
        engine.handleConfigurationChange()
        var iterator = engine.events.makeAsyncIterator()
        #expect(await iterator.next() == .configurationChanged)
        // Da tiempo a la cola de ciclo de vida a procesar (y descartar) el rearranque.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!engine.isRunning)
    }
}
