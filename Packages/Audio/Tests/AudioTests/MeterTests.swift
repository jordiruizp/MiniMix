import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// T40 · Vúmetros: valores (dBFS pico) y frecuencia de emisión (~30 Hz).
@Suite struct MeterTests {
    @Test func peakLevelsPerChannelAndMaster() async throws {
        let engine = try makeOfflineEngine()
        let a = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        let b = makeSource(.silence)
        for source in [a, b] {
            engine.setAudioFollowsProgram(false, for: source.id)
            try engine.attach(source)
        }
        engine.setVolume(2, for: a.id)
        engine.setMasterVolume(0.5)
        try engine.start()
        _ = try render(engine, frames: 2_048)
        engine.publishMetersNow() // descarta la rampa inicial (si la hubiera)
        _ = try render(engine, frames: 1_024)
        engine.publishMetersNow()

        let levels = try #require(await nextLevels(engine))
        #expect(Set(levels.keys) == [a.id, b.id, nil])
        // a: 0,5 · 2 = 1,0 → 0 dBFS (post-fader), en L y R.
        for value in try #require(levels[a.id]) { #expect(abs(value) < 0.01) }
        #expect(levels[b.id] == [Decibels.silenceFloor, Decibels.silenceFloor])
        // Master: 1,0 · 0,5 → −6,02 dBFS.
        for value in try #require(levels[nil]) { #expect(abs(value - 20 * log10(0.5)) < 0.01) }

        // Sin render entre dos lecturas no hay picos: silencio.
        engine.publishMetersNow()
        let idle = try #require(await nextLevels(engine))
        #expect(idle[nil] == [Decibels.silenceFloor, Decibels.silenceFloor])

        // Al quitar la entrada desaparece de los vúmetros.
        engine.detach(b.id)
        engine.publishMetersNow()
        #expect(try #require(await nextLevels(engine)).keys.contains(b.id) == false)
    }

    /// Cuenta las emisiones durante ~1 s (tolerancia amplia: la máquina de CI está compartida).
    @Test func metersArePublishedAbout30TimesPerSecond() async throws {
        let engine = try makeOfflineEngine(meterRate: 30)
        try engine.attach(makeSource(.sine(frequency: 1_000, amplitude: 0.5)))
        let count = Locked(0)
        let consumer = Task {
            for await _ in engine.meters { count.withLock { $0 += 1 } }
        }
        try engine.start()
        try await Task.sleep(for: .seconds(1))
        engine.stop()
        let emitted = count.current
        consumer.cancel()
        print("[T40] meters: \(emitted) emisiones en ~1 s")
        #expect((20...40).contains(emitted))
    }

    @Test func decibelConversion() {
        #expect(Decibels.fromLinear(1) == 0)
        #expect(abs(Decibels.fromLinear(0.5) - -6.0206) < 1e-3)
        #expect(Decibels.fromLinear(0) == Decibels.silenceFloor)
        #expect(Decibels.fromLinear(1e-12) == Decibels.silenceFloor)
        #expect(Decibels.fromLinear(.nan) == Decibels.silenceFloor)
    }
}
