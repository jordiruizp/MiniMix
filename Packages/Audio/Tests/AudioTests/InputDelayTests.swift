import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// Retardo por entrada (sincronismo A/V): manual, perfil `.playerTap` y posición antes del gate.
@Suite struct InputDelayTests {
    static func firstOnset(_ samples: [Float], threshold: Float = 0.25) -> Int? {
        samples.firstIndex { abs($0) >= threshold }
    }

    @Test func manualDelayShiftsTheInput() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.step(start: 1_000, level: 0.5))
        engine.setAudioFollowsProgram(false, for: source.id)
        engine.setInputDelay(milliseconds: 10, for: source.id)
        try engine.attach(source)
        try engine.start()
        #expect(Self.firstOnset(try render(engine, frames: 4_800)) == 1_000 + 480)
        #expect(engine.inputDelayMilliseconds(for: source.id) == 10)
    }

    @Test func playerTapProfileUsesCalibratedLeadPlusVideoLatency() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.step(start: 0, level: 0.5))
        engine.setAudioFollowsProgram(false, for: source.id)
        engine.videoPresentationLatency = 0.02
        engine.setSyncProfile(.playerTap, for: source.id)
        try engine.attach(source)
        try engine.start()
        let expected = Int(((AudioEngine.playerTapLead + 0.02) * testSampleRate).rounded())
        print("[AV] retardo .playerTap con vídeo a 20 ms: \(engine.inputDelayMilliseconds(for: source.id)) ms")
        #expect(Self.firstOnset(try render(engine, frames: 9_600)) == expected)
        #expect(abs(engine.inputDelayMilliseconds(for: source.id) - (AudioEngine.playerTapLead + 0.02) * 1_000) < 1e-9)

        // Límite: maxInputDelay (0,25 s por defecto).
        engine.setInputDelay(milliseconds: 1_000, for: source.id)
        #expect(engine.inputDelayMilliseconds(for: source.id) == 250)
    }

    /// El retardo va antes del gate de Programa: al cortar a otra entrada, el audio retrasado deja
    /// de sonar con la rampa del corte (no `delay` más tarde). Así el fundido actúa sobre el audio
    /// ya alineado con su vídeo.
    @Test func delayIsAppliedBeforeTheProgramGate() throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(.step(start: 0, level: 0.5))
        engine.setInputDelay(milliseconds: 100, for: source.id) // 4 800 muestras
        try engine.attach(source)
        engine.setProgram(source.id)
        try engine.start()
        var samples = try render(engine, frames: 7_168)
        engine.setProgram(nil) // corte en la muestra 7 168
        samples += try render(engine, frames: 9_600)

        #expect(Self.firstOnset(samples) == 4_800)
        let lastLoud = try #require(samples.lastIndex { abs($0) >= 0.01 })
        // Gate a 0 en 20 ms (960 muestras) desde el corte; si el retardo fuese posterior al gate
        // seguiría sonando hasta 7 168 + 4 800.
        #expect(lastLoud < 7_168 + 960)
    }
}
