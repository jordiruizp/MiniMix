import AVFAudio
import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// T40 · mute, solo-escucha, Master, alta/baja de canales y compensación de latencia.
@Suite struct MixerTests {
    @Test func muteSilencesChannel() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        try engine.start()
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.5) < 1e-3)
        engine.setMute(true, for: source.id)
        #expect(peak(try render(engine, frames: 2_048), last: 480) == 0)
        engine.setMute(false, for: source.id)
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.5) < 1e-3)
    }

    @Test func masterVolumeScalesOutput() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: 0.4))
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        try engine.start()
        engine.setMasterVolume(0.5)
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.2) < 1e-3)
        engine.setMasterVolume(9) // se limita a 2
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.8) < 1e-3)
    }

    @Test func soloOnlyAffectsListening() async throws {
        let engine = try makeOfflineEngine()
        let a = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        let b = makeSource(.step(start: 0, level: 0.25))
        for source in [a, b] {
            engine.setAudioFollowsProgram(false, for: source.id)
            try engine.attach(source)
        }
        try engine.start()

        // Sin solo se escucha Master = a + b.
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.75) < 1e-3)

        // Solo en b: se escucha solo b; Master (vúmetro) sigue siendo a + b.
        engine.setSolo(true, for: b.id)
        _ = try render(engine, frames: 2_048)
        engine.publishMetersNow() // descarta los picos de la rampa
        let listened = try render(engine, frames: 2_048)
        #expect(abs(peak(listened, last: 480) - 0.25) < 1e-3)
        #expect(abs(listened.last! - 0.25) < 1e-3)
        engine.publishMetersNow()
        let levels = try #require(await nextLevels(engine))
        let master = try #require(levels[nil])
        #expect(abs(master[0] - Decibels.fromLinear(0.75)) < 0.01)

        // Solo en b aunque esté fuera de Programa (preescucha).
        engine.setAudioFollowsProgram(true, for: b.id)
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.25) < 1e-3)

        // Quitar el solo vuelve a Master (b ya no suena: sigue a Programa y no está en él).
        engine.setSolo(false, for: b.id)
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.5) < 1e-3)
    }

    @Test func detachRemovesChannelAndReattachWorks() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        engine.setAudioFollowsProgram(false, for: source.id)
        engine.setVolume(0.5, for: source.id)
        try engine.attach(source)
        try engine.start()
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.25) < 1e-3)
        engine.detach(source.id)
        #expect(engine.attachedInputs.isEmpty)
        #expect(peak(try render(engine, frames: 2_048), last: 480) == 0)
        // Los ajustes se conservan al volver a conectar (con el motor en marcha).
        try engine.attach(source)
        #expect(engine.attachedInputs == [source.id])
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.25) < 1e-3)
    }

    @Test func sourceWithoutNodeIsIgnored() throws {
        let engine = try makeOfflineEngine()
        try engine.attach(MockAudioSource())
        #expect(engine.attachedInputs.isEmpty)
    }

    @Test func nodeFromAnotherEngineIsRejected() throws {
        let engine = try makeOfflineEngine()
        let other = AVAudioEngine()
        let source = makeSource(.silence)
        other.attach(source.node!)
        #expect(throws: AudioEngineError.nodeAttachedToAnotherEngine) { try engine.attach(source) }
    }

    @Test func latencyCompensationDelaysOutput() throws {
        for milliseconds in [0.0, 10, 125] {
            let engine = try makeOfflineEngine()
            let source = makeSource(.step(start: 1_000, level: 0.5))
            engine.setAudioFollowsProgram(false, for: source.id)
            engine.setLatencyCompensation(milliseconds: milliseconds)
            try engine.attach(source)
            try engine.start()
            let samples = try render(engine, frames: 12_000)
            let onset = try #require(samples.firstIndex { $0 > 0.25 })
            let expected = 1_000 + Int(milliseconds / 1_000 * testSampleRate)
            print("[T40] latency \(milliseconds) ms → onset \(onset) (esperado \(expected))")
            #expect(onset == expected)
            #expect(engine.latencyCompensationMilliseconds == milliseconds)
        }
    }

    @Test func latencyChangeWhileRunningHasNoClicks() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        try engine.start()
        var samples = try render(engine, frames: 2_400)
        engine.latencyCompensationMilliseconds = 40
        samples += try render(engine, frames: 4_800)
        engine.latencyCompensationMilliseconds = 5_000 // se limita al máximo configurado (1 s)
        samples += try render(engine, frames: 4_800)
        #expect(engine.latencyCompensationMilliseconds == 1_000)
        let jump = maxEnvelopeJump(envelope(samples, window: 48))
        #expect(jump < 0.06)
    }
}

/// Siguiente mensaje de `meters` (con `bufferingNewest(1)`, el último publicado).
func nextLevels(_ engine: AudioEngine) async -> [InputID?: [Float]]? {
    var iterator = engine.meters.makeAsyncIterator()
    return await iterator.next()
}
