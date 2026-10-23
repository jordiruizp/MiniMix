import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// T41 · Audio sigue a Programa y fundido sincronizado con la transición de vídeo.
@Suite struct ProgramFollowTests {
    static let points = (0...40).map { Double($0) / 40 }

    @Test func gainsMatchVideoCurveWithEqualPower() {
        let a = InputID(), b = InputID(), other = InputID()
        for progress in Self.points {
            let follow = ProgramFollow(from: a, to: b, progress: progress)
            let expected = TransitionCurve.audioGains(progress)
            #expect(follow.gain(for: a) == Float(expected.outgoing))
            #expect(follow.gain(for: b) == Float(expected.incoming))
            #expect(follow.gain(for: other) == 0)
            let power = pow(Double(follow.gain(for: a)), 2) + pow(Double(follow.gain(for: b)), 2)
            #expect(abs(power - 1) < 1e-6)
            // La ganancia entrante sigue la mezcla de vídeo: asin(g)·2/π == videoMix(p).
            let mix = asin(min(1, Double(follow.gain(for: b)))) * 2 / .pi
            #expect(abs(mix - TransitionCurve.videoMix(progress)) < 1e-3)
        }
    }

    @Test func edgeCases() {
        let a = InputID(), b = InputID()
        #expect(ProgramFollow.empty.gain(for: a) == 0)
        #expect(ProgramFollow(program: a).gain(for: a) == 1)
        #expect(ProgramFollow(program: a).program == a)
        #expect(ProgramFollow(from: a, to: a, progress: 0.3).gain(for: a) == 1)
        #expect(ProgramFollow(from: a, to: b, progress: -1).gain(for: a) == 1)
        #expect(ProgramFollow(from: a, to: b, progress: 7).gain(for: b) == 1)
        #expect(ProgramFollow(from: a, to: b, progress: .nan).gain(for: a) == 1)
        #expect(ProgramFollow(from: nil, to: b, progress: 0.5).gain(for: b)
                == Float(TransitionCurve.audioGains(0.5).incoming))
    }

    @Test func engineAppliesCurveToFollowingChannelsOnly() throws {
        let engine = try makeOfflineEngine()
        let a = makeSource(.silence), b = makeSource(.silence)
        let free = makeSource(.silence), idle = makeSource(.silence)
        engine.setAudioFollowsProgram(false, for: free.id)
        engine.setVolume(0.7, for: free.id)
        for source in [a, b, free, idle] { try engine.attach(source) }

        for progress in Self.points {
            engine.transition(from: a.id, to: b.id, progress: progress)
            let expected = TransitionCurve.audioGains(progress)
            #expect(engine.targetGains(for: a.id)?.program == Float(expected.outgoing))
            #expect(engine.targetGains(for: b.id)?.program == Float(expected.incoming))
            #expect(engine.targetGains(for: free.id) == ChannelGains(fader: 0.7, program: 1, solo: 0))
            #expect(engine.targetGains(for: idle.id)?.program == 0)
        }
        // Al terminar, b queda en Programa.
        engine.setProgram(b.id)
        #expect(engine.targetGains(for: b.id)?.program == 1)
        #expect(engine.targetGains(for: a.id)?.program == 0)
        // Dejar de seguir a Programa: suena siempre con su fader.
        engine.setAudioFollowsProgram(false, for: a.id)
        #expect(engine.targetGains(for: a.id)?.program == 1)
    }

    /// Medido en la salida real: igual potencia entre saliente y entrante.
    @Test func renderedFadeHasEqualPower() throws {
        let amplitude: Float = 0.5
        var outgoing: [Float] = []
        var incoming: [Float] = []
        // Dos pasadas: solo la saliente con señal, y solo la entrante con señal.
        for pass in 0..<2 {
            let engine = try makeOfflineEngine()
            let a = makeSource(pass == 0 ? .sine(frequency: 1_000, amplitude: amplitude) : .silence)
            let b = makeSource(pass == 1 ? .sine(frequency: 1_000, amplitude: amplitude) : .silence)
            try engine.attach(a)
            try engine.attach(b)
            try engine.start()
            for progress in Self.points {
                engine.transition(from: a.id, to: b.id, progress: progress)
                let level = peak(try render(engine, frames: 2_048), last: 480) / amplitude
                if pass == 0 { outgoing.append(level) } else { incoming.append(level) }
            }
        }
        var worstPower: Double = 0
        for (index, progress) in Self.points.enumerated() {
            let expected = TransitionCurve.audioGains(progress)
            #expect(abs(Double(outgoing[index]) - expected.outgoing) < 1e-3)
            #expect(abs(Double(incoming[index]) - expected.incoming) < 1e-3)
            let power = Double(outgoing[index] * outgoing[index] + incoming[index] * incoming[index])
            worstPower = max(worstPower, abs(power - 1))
        }
        print("[T41] rendered fade: max |g_out² + g_in² − 1| = \(worstPower)")
        #expect(worstPower < 2e-3)
    }

    /// Integración tal como la hará T80: una llamada por tick (60 fps) durante un fundido de 1 s.
    /// La rampa de 20 ms suaviza los escalones por fotograma; mide el desfase frente a la curva.
    @Test func tickDrivenFadeFollowsCurve() throws {
        let engine = try makeOfflineEngine()
        let a = makeSource(.silence), b = makeSource(.silence)
        try engine.attach(a)
        try engine.attach(b)
        engine.setProgram(a.id)
        try engine.start()
        _ = try render(engine, frames: 2_048)

        let ticks = 60
        let framesPerTick = Int(testSampleRate) / ticks
        var worst: Float = 0
        for tick in 1...ticks {
            let progress = Double(tick) / Double(ticks)
            engine.transition(from: a.id, to: b.id, progress: progress)
            _ = try render(engine, frames: framesPerTick)
            let expected = Float(TransitionCurve.audioGains(progress).incoming)
            worst = max(worst, abs(try #require(engine.appliedProgramGain(for: b.id)) - expected))
        }
        engine.setProgram(b.id)
        _ = try render(engine, frames: 2_048)
        print("[T41] tick-driven fade: max |applied − curve| at tick end = \(worst)")
        #expect(worst < 0.01)
        #expect(engine.appliedProgramGain(for: b.id) == 1)
        #expect(engine.appliedProgramGain(for: a.id) == 0)
    }
}
