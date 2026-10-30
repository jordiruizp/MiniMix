import AVFoundation
import Core
import Foundation
import Testing
@testable import Media

extension MediaSerialTests {
    /// Sincronía A/V del arranque (Ola 3): clics del archivo frente al vídeo, con un
    /// motor de audio en tiempo real (volumen 0). Error > 0 = audio tarde.
    @Suite(.enabled(if: GPU.available), .timeLimit(.minutes(2)))
    struct AVSyncTests {
        let cache = VideoTextureCache(context: GPU.context!)

        private func clickVideo() async throws -> URL {
            try await TestMediaFactory.shared.video(
                Spec(width: 320, height: 180, fps: 30, seconds: 5, audio: true, clicks: true))
        }

        /// `runs` arranques desde 0; devuelve los onsets de los primeros 2,5 s de cada uno.
        private func measure(_ input: VideoInput, probe: AVSyncProbe, runs: Int, label: String,
                             start: (VideoInput) -> Void) async throws -> [[AVSyncProbe.Onset]] {
            var result: [[AVSyncProbe.Onset]] = []
            for run in 0..<runs {
                await input.seek(to: 0)
                try await Task.sleep(for: .milliseconds(300))
                probe.reset()
                let playHost = HostClock.hostTime(nanos: HostClock.nowNanos()).seconds
                start(input)
                try await Task.sleep(for: .milliseconds(2_500))
                // Medir antes de pausar: en pausa el timebase deja de avanzar.
                let onsets = probe.onsets(input: input, playHost: playHost).filter { $0.sincePlay > 0 }
                input.pause()
                let text = onsets.map { String(format: "%+.1f ms@%.2fs", $0.errorMs, $0.sincePlay) }.joined(separator: ", ")
                print("[AV] \(label) arranque \(run): \(text)")
                result.append(onsets)
            }
            return result
        }

        @Test func startupAudioIsAlignedFromTheFirstSecond() async throws {
            let input = VideoInput(url: try await clickVideo(), textureCache: cache)
            try await input.prepare()
            guard let probe = AVSyncProbe(node: try #require(input.node)) else {
                print("[AV] sin dispositivo de salida de audio: no se mide")
                return
            }
            defer { probe.stop() }
            let ring = try #require(input.audioTapForTesting?.ring)
            print("[AV] latencia de salida \(String(format: "%.1f", probe.outputLatency * 1000)) ms")

            // Antes: sin alineación por tiempo de item (cola simple, como hasta ahora).
            ring.alignmentEnabled.store(false, ordering: .relaxed)
            let before = try await measure(input, probe: probe, runs: 3, label: "sin alinear") { $0.play() }
            ring.alignmentEnabled.store(true, ordering: .relaxed)
            let after = try await measure(input, probe: probe, runs: 3, label: "alineado") { $0.play() }

            let firstBefore = before.compactMap(\.first?.errorMs)
            let firstAfter = after.compactMap(\.first?.errorMs)
            let allAfter = after.flatMap { $0.map(\.errorMs) }
            print("[AV] primer clic sin alinear \(firstBefore.map { String(format: "%+.1f", $0) }) ms · " +
                  "alineado \(firstAfter.map { String(format: "%+.1f", $0) }) ms · " +
                  "alineado todos: medio \(String(format: "%+.1f", allAfter.reduce(0, +) / Double(max(allAfter.count, 1)))) ms, " +
                  "rango \(String(format: "%+.1f…%+.1f", allAfter.min() ?? 0, allAfter.max() ?? 0)) ms")
            #expect(after.allSatisfy { !$0.isEmpty })
            // Alineado desde el primer clic (0,1 s tras play) y estable entre arranques.
            PerfGate.check(allAfter.allSatisfy { abs($0) < 10 }, "error A/V alineado < 10 ms: \(allAfter)")
            PerfGate.check((allAfter.max() ?? 0) - (allAfter.min() ?? 0) < 6, "variación entre arranques < 6 ms")
        }

        /// `play(atHostTime:)`: la posición actual se presenta exactamente en ese host.
        @Test func playAtHostTimeStartsOnTheTick() async throws {
            let input = VideoInput(url: try await clickVideo(), textureCache: cache)
            try await input.prepare()
            await input.seek(to: 1.0)
            let start = HostClock.hostTime(nanos: HostClock.nowNanos()) + 0.3
            input.play(atHostTime: start)
            try await Task.sleep(for: .milliseconds(150))
            #expect(abs((input.currentTime ?? -1) - 1.0) < 0.02) // aún no ha empezado
            try await Task.sleep(for: .milliseconds(400))
            let atStart = try #require(input.itemTimeForTesting(hostSeconds: start.seconds))
            let later = try #require(input.itemTimeForTesting(hostSeconds: start.seconds + 0.2))
            input.pause()
            print(String(format: "[AV] play(atHostTime:) item en el tick %.4f s (esperado 1,0000), +0,2 s → %.4f", atStart, later))
            #expect(abs(atStart - 1.0) < 0.002)
            #expect(abs(later - 1.2) < 0.002)
        }
    }
}
