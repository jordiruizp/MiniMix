import Core
import CoreMocks
import Testing
@testable import Audio

/// Altas y bajas de canales con el motor en marcha, sin clics.
@Suite struct DetachTests {
    static let amplitude: Float = 0.5
    /// Mismo umbral que `FaderRampTests` (rampa de 20 ms, seno de 1 kHz).
    static let maxJump: Float = 0.03

    @Test func detachWhileRunningRampsOutWithoutClick() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: Self.amplitude))
        engine.setAudioFollowsProgram(false, for: source.id)
        engine.setVolume(2, for: source.id)
        try engine.attach(source)
        try engine.start()
        var samples = try render(engine, frames: 2_400)
        engine.detach(source.id)
        #expect(engine.attachedInputs.isEmpty)
        #expect(engine.retiringCount == 1)
        samples += try render(engine, frames: 4_800)

        let jump = maxEnvelopeJump(envelope(samples, window: 48))
        print("[T40] detach: max envelope jump per sample = \(jump)")
        // Volumen 2 → amplitud 1,0: peor caso teórico 24 · (2/960) · 0,5 ≈ 0,025 (sin rampa: 1,0).
        #expect(jump < 0.04)
        #expect(peak(samples, last: 2_400) == 0)
        // 20 ms de rampa + 50 ms de margen < 100 ms renderizados: ya desmontado.
        #expect(engine.retiringCount == 0)
    }

    @Test func reattachDuringRampOutResumesWithoutClick() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: Self.amplitude))
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        try engine.start()
        var samples = try render(engine, frames: 2_400)
        engine.detach(source.id)
        samples += try render(engine, frames: 300) // a mitad de la rampa
        try engine.attach(source)
        #expect(engine.attachedInputs == [source.id])
        #expect(engine.retiringCount == 0)
        samples += try render(engine, frames: 4_800)

        #expect(maxEnvelopeJump(envelope(samples, window: 48)) < Self.maxJump)
        #expect(abs(peak(samples, last: 480) - Self.amplitude) < 1e-3)
    }

    @Test func attachAndReplaceWhileRunningWithoutClick() throws {
        let engine = try makeOfflineEngine()
        let id = InputID()
        let first = makeSource(.sine(frequency: 1_000, amplitude: Self.amplitude), id: id)
        let second = makeSource(.sine(frequency: 1_000, amplitude: 0.25), id: id)
        engine.setAudioFollowsProgram(false, for: id)
        try engine.start()
        var samples = try render(engine, frames: 1_024)
        try engine.attach(first) // alta en marcha: el fader sube desde 0
        samples += try render(engine, frames: 2_400)
        try engine.attach(second) // sustitución: el anterior baja con rampa
        samples += try render(engine, frames: 4_800)

        #expect(maxEnvelopeJump(envelope(samples, window: 48)) < Self.maxJump)
        #expect(abs(peak(samples, last: 480) - 0.25) < 1e-3)
        #expect(engine.retiringCount == 0)
    }

    @Test func detachWhileStoppedIsImmediate() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.silence)
        try engine.attach(source)
        engine.detach(source.id)
        #expect(engine.retiringCount == 0)
        #expect(source.node?.engine == nil)
    }
}
