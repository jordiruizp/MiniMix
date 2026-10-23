import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// T40 · Aceptación: sin clics al mover el fader (render manual offline).
@Suite struct FaderRampTests {
    /// Seno de 1 kHz a 48 kHz → 48 muestras por periodo exactas: con ganancia constante la
    /// envolvente (máximo en una ventana de un periodo) es constante; cualquier salto procede de
    /// cambios de ganancia. Saltos de fader 0↔2 sin rampa darían ~1,0 en la envolvente.
    static let amplitude: Float = 0.5
    static let period = 48
    /// Umbral de salto de envolvente por muestra. Con rampa de 20 ms el peor caso teórico es
    /// medio periodo de rampa 0→2: 24 · (2/960) · 0,5 = 0,025.
    static let maxJump: Float = 0.03

    @Test func faderMovesHaveNoClicks() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: Self.amplitude))
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        try engine.start()

        var samples = try render(engine, frames: 4_800)
        // Movimientos bruscos del fader, incluidos cambios a mitad de una rampa.
        for (volume, frames) in [(Float(2), 2_400), (0, 2_400), (1.5, 300), (0.1, 2_400),
                                 (2, 2_400), (0, 2_400), (1, 2_400)] {
            engine.setVolume(volume, for: source.id)
            samples += try render(engine, frames: frames)
        }
        // También mute/unmute y Master.
        engine.setMute(true, for: source.id)
        samples += try render(engine, frames: 2_400)
        engine.setMute(false, for: source.id)
        samples += try render(engine, frames: 2_400)
        engine.setMasterVolume(2)
        samples += try render(engine, frames: 2_400)
        engine.setMasterVolume(0)
        samples += try render(engine, frames: 2_400)

        let jump = maxEnvelopeJump(envelope(samples, window: Self.period))
        print("[T40] max envelope jump per sample: \(jump) (umbral \(Self.maxJump))")
        #expect(jump < Self.maxJump)
        // Sin rampa, el mismo salto 2 → 0 sería ~2 · 0,5 = 1,0.
        #expect(jump < 0.05 * 2 * Self.amplitude)
    }

    @Test func rampDurationIsAbout20ms() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: Self.amplitude))
        engine.setAudioFollowsProgram(false, for: source.id)
        engine.setVolume(0, for: source.id)
        try engine.attach(source)
        try engine.start()
        _ = try render(engine, frames: 2_048)

        engine.setVolume(2, for: source.id)
        let env = envelope(try render(engine, frames: 4_800), window: Self.period)
        let target = 2 * Self.amplitude
        // Primer índice de la envolvente (ventana que acaba en idx + period - 1) que llega al 99 %.
        let reached = try #require(env.firstIndex { $0 >= 0.99 * target })
        let rampMs = Double(reached + Self.period - 1) / testSampleRate * 1_000
        print("[T40] ramp 0→2 reaches 99 % at \(rampMs) ms")
        #expect(rampMs > 15 && rampMs < 25)
        #expect(abs(env.last! - target) < 0.001)
    }

    @Test func gainIsLinear() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: Self.amplitude))
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        try engine.start()
        for volume in [Float(0), 0.25, 1, 1.5, 2] {
            engine.setVolume(volume, for: source.id)
            let samples = try render(engine, frames: 2_048)
            #expect(abs(peak(samples, last: 480) - volume * Self.amplitude) < 1e-3)
        }
    }
}
