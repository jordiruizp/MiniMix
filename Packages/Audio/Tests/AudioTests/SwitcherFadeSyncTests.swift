import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// Plan 10.2 / T41 en la integración: el fundido de audio llamado desde los ticks reales del
/// switcher (`SwitcherState.tick` → `.transitionProgress` → `AudioEngine.transition`, como hace
/// `AppViewModel`) sigue la misma curva que el vídeo de ese tick (`TransitionCurve.videoMix`),
/// con un desfase ≤ 1 fotograma.
@Suite struct SwitcherFadeSyncTests {
    /// Progreso p con smoothstep(p) = mix (bisección; smoothstep es monótona en 0…1).
    static func inverseSmoothstep(_ mix: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if TransitionCurve.videoMix(mid) < mix { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// Progreso equivalente a una ganancia entrante aplicada (incoming = sin(mix·π/2)).
    static func progress(forIncomingGain gain: Float) -> Double {
        inverseSmoothstep(asin(min(1, max(0, Double(gain)))) * 2 / .pi)
    }

    @Test(arguments: [(FrameRate.fps60, 1.0), (FrameRate.fps30, 0.5), (FrameRate.fps25, 2.0)])
    func audioFadeFollowsVideoMixOfEachTick(rate: FrameRate, duration: Double) throws {
        let engine = try makeOfflineEngine()
        let a = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        let b = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        try engine.attach(a)
        try engine.attach(b)
        var switcher = SwitcherState(preview: b.id, program: a.id)
        engine.setProgram(a.id)
        try engine.start()
        _ = try render(engine, frames: 2_048)

        // Igual que AppViewModel.handle(_:).
        var inputs: (from: InputID?, to: InputID?)?
        var videoProgress = 0.0
        func handle(_ effects: [Effect]) {
            for effect in effects {
                switch effect {
                case let .transitionStarted(_, from, to, _): inputs = (from, to)
                case .transitionProgress(let progress):
                    videoProgress = progress
                    engine.transition(from: inputs?.from, to: inputs?.to, progress: progress)
                case .transitionCompleted, .transitionCancelled: inputs = nil
                default: break
                }
            }
        }

        let frame = rate.frameDuration
        let framesPerTick = Int((frame * testSampleRate).rounded())
        let start = HostTime(seconds: 100)
        handle(switcher.apply(.fade(duration: duration), at: start))
        var worstLagFrames = 0.0
        var worstPower = 0.0
        var tick = 0
        while inputs != nil {
            tick += 1
            handle(switcher.tick(at: start + Double(tick) * frame))
            _ = try render(engine, frames: framesPerTick) // audio de este fotograma
            let incoming = try #require(engine.appliedProgramGain(for: b.id))
            let outgoing = try #require(engine.appliedProgramGain(for: a.id))
            let lag = (videoProgress - Self.progress(forIncomingGain: incoming)) * duration / frame
            worstLagFrames = max(worstLagFrames, abs(lag))
            worstPower = max(worstPower, abs(Double(incoming * incoming + outgoing * outgoing) - 1))
        }
        _ = try render(engine, frames: 2_048)
        print("[T41] \(rate.fps) fps, fundido \(duration) s, \(tick) ticks: desfase audio/vídeo máx "
              + String(format: "%.2f fotogramas, |g² + g² − 1| máx %.4f", worstLagFrames, worstPower))
        #expect(worstLagFrames <= 1)
        #expect(engine.appliedProgramGain(for: b.id) == 1)
        #expect(engine.appliedProgramGain(for: a.id) == 0)
    }
}
