import Core
import Foundation
import Testing
@testable import Media

extension MediaSerialTests {
    /// Diagnóstico (MINIMIX_HFR_MEDIA=<TestMedia/video de H>): réplica reducida del escenario
    /// «stress-2h-cuts» de H (5 vídeos, Preview + Programa, corte cada 3 s, render a 60 Hz) y
    /// cuenta los fotogramas que salta cada fuente mientras se ve.
    @Suite(.enabled(if: GPU.available && ProcessInfo.processInfo.environment["MINIMIX_HFR_MEDIA"] != nil),
           .timeLimit(.minutes(10)))
    struct CutScenarioDiagnosticTests {
        @Test func cutsEveryThreeSeconds() async throws {
            let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MINIMIX_HFR_MEDIA"]!)
            let files = ["h264_1080p25.mp4", "h264_1080p2997.mp4", "hevc_1080p25.mp4", "h264_1080p5994.mp4", "h264_1080p50.mp4"]
            let manager = InputManager(context: GPU.context!)
            var ids: [InputID] = []
            for file in files {
                let d = InputDescriptor(name: file, content: .video(MediaReference(path: dir.appendingPathComponent(file).path)),
                                        loop: true)
                try await manager.add(d)
                ids.append(d.id)
            }
            let videos = ids.compactMap { manager.frameSource(for: $0) as? VideoInput }
            videos.forEach { $0.play() }
            var preview = 1
            var program = 0
            manager.setVisible([ids[program], ids[preview]])
            let displayLink = ProcessInfo.processInfo.environment["MINIMIX_HFR_DISPLAYLINK"] != nil
            let source: MasterClock.TickSource = displayLink ? .displayLink : .timer
            let clock = MasterClock(frameRate: .fps60, tickSource: source)
            let ticks = clock.ticks
            clock.start()
            let bus = LockedState((program: 0, preview: 1))
            let render = Task {
                for await tick in ticks {
                    let (p, v) = bus.current
                    _ = videos[p].texture(for: tick)
                    _ = videos[v].texture(for: tick)
                }
            }
            let seconds = Double(ProcessInfo.processInfo.environment["MINIMIX_HFR_SECONDS"] ?? "60") ?? 60
            var skippedOnAir = [Int](repeating: 0, count: videos.count)
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                let before = videos[program].stats.droppedFrames
                try await Task.sleep(for: .seconds(3))
                skippedOnAir[program] += videos[program].stats.droppedFrames - before
                // Corte: Preview pasa a Programa; el siguiente vídeo entra en Preview.
                program = preview
                preview = (preview + 1) % videos.count
                bus.withLock { $0 = (program, preview) }
                manager.setVisible([ids[program], ids[preview]])
            }
            clock.stop()
            _ = await render.value
            videos.forEach { $0.pause() }
            for (i, file) in files.enumerated() {
                print("[T31] corte cada 3 s, \(file): saltados en Programa \(skippedOnAir[i]), total \(videos[i].stats.droppedFrames)")
            }
            print("[T30] ticks saltados \(clock.stats.skippedTicks) (\(clock.tickSource))")
        }
    }
}
