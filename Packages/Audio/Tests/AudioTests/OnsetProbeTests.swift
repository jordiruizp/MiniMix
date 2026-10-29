import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// Detector de inicios a la salida del motor (medición de claqueta).
@Suite struct OnsetProbeTests {
    /// Pitido de claqueta: 1 kHz, 40 ms, amplitud 0,6 cada `period` muestras, sobre un tono de 0,05.
    static func clapper(period: Int) -> TestSignal {
        .custom { frame in
            let inBeat = frame % period
            let tone = 0.05 * Float(sin(2 * Double.pi * 300 * Double(frame) / testSampleRate))
            guard inBeat < 1_920 else { return tone }
            return tone + 0.6 * Float(sin(2 * Double.pi * 1_000 * Double(inBeat) / testSampleRate))
        }
    }

    @Test func detectsBeepOnsetsAtTheirSample() async throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(Self.clapper(period: 12_000))
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        let onsets = engine.startOnsetDetection(threshold: 0.3, holdOff: 0.1)
        try engine.start()
        _ = try render(engine, frames: 48_000)
        engine.stopOnsetDetection()

        var found: [AudioOnset] = []
        for await onset in onsets { found.append(onset) }
        print("[AV] onsets offline: \(found.map(\.sampleTime))")
        // 4 pitidos (0; 0,25; 0,5; 0,75 s). La 1.ª muestra ≥ 0,3 llega a ~30° de fase (≈ 4 muestras).
        #expect(found.count == 4)
        for (index, onset) in found.enumerated() {
            #expect(abs(onset.sampleTime - Int64(index * 12_000)) <= 8)
            #expect(onset.renderHostTime == nil)
        }
    }

    @Test func onsetsIncludeLatencyCompensation() async throws {
        let engine = try makeOfflineEngine()
        let source = makeSource(Self.clapper(period: 24_000))
        engine.setAudioFollowsProgram(false, for: source.id)
        engine.setLatencyCompensation(milliseconds: 20)
        try engine.attach(source)
        let onsets = engine.startOnsetDetection(threshold: 0.3, holdOff: 0.1)
        try engine.start()
        _ = try render(engine, frames: 48_000)
        engine.stopOnsetDetection()

        var found: [Int64] = []
        for await onset in onsets { found.append(onset.sampleTime) }
        #expect(found.count == 2)
        #expect(found.allSatisfy { abs(($0 % 24_000) - 960) <= 8 })
    }
}
