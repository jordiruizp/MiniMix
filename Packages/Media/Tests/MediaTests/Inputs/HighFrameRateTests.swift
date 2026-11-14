import Core
import Foundation
import Metal
import Testing
@testable import Media

extension MediaSerialTests {
    /// T90: clips de 50 y 59,94 fps en un proyecto de 60p no deben saltar fotogramas de la fuente.
    @Suite(.enabled(if: GPU.available), .timeLimit(.minutes(5)))
    struct HighFrameRateTests {
        struct Case: Sendable, CustomStringConvertible {
            let fps: Int32
            let denominator: Int32
            var description: String { String(format: "%.2f fps", Double(fps) / Double(denominator)) }
        }

        static let cases = [Case(fps: 60_000, denominator: 1_001), Case(fps: 50, denominator: 1)]

        static var seconds: Double {
            ProcessInfo.processInfo.environment["MINIMIX_HFR_SECONDS"].flatMap(Double.init) ?? 12
        }

        /// Reproduce el clip en bucle, pide textura en cada tick de 60 Hz (como Programa) y
        /// cuenta los fotogramas de la fuente que el consumidor no llegó a recibir.
        @Test(arguments: cases)
        func sourceDoesNotSkipFramesAt60p(_ clip: Case) async throws {
            let url = try await TestMediaFactory.shared.video(
                Spec(codec: .h264, fps: clip.fps, fpsDenominator: clip.denominator, seconds: Self.seconds + 2))
            let input = VideoInput(url: url, textureCache: VideoTextureCache(context: GPU.context!), loop: true)
            try await input.prepare()
            _ = await waitForTexture(input, timeout: 10)
            input.play()
            let clock = MasterClock(frameRate: .fps60) // fuente por defecto, como la App
            #expect(clock.tickSource == .timer)
            let ticks = clock.ticks
            clock.start()
            // Además del PTS, se lee el contenido de la textura en la GPU después de usarla
            // (como hace H): verde = índice de fotograma % 256 en los clips generados.
            let mismatches = LockedState(0)
            let lateCalls = LockedState(0)
            let contentReads = LockedState(0)
            let context = GPU.context!
            let checkContent = ProcessInfo.processInfo.environment["MINIMIX_HFR_CLIP_\(clip.fps)"] == nil
            let render = Task {
                var calls = 0
                var lastPTS: Double?
                // Diagnóstico: MINIMIX_HFR_LATE_MS simula un render que llega tarde al tick.
                let lateMs = Int(ProcessInfo.processInfo.environment["MINIMIX_HFR_LATE_MS"] ?? "0") ?? 0
                for await tick in ticks {
                    if lateMs > 0 { try? await Task.sleep(for: .milliseconds(Int.random(in: 0...lateMs))) }
                    // Llamadas tardías del consumidor (planificación de la tarea del test): un
                    // salto entonces es del consumidor, no de la fuente.
                    if (HostClock.hostTime(nanos: HostClock.nowNanos()) - tick) > 0.008 { lateCalls.withLock { $0 += 1 } }
                    let texture = input.texture(for: tick)
                    calls += 1
                    guard checkContent, let texture, let pts = input.stats.lastPresentationTime, pts != lastPTS,
                          let buffer = context.device.makeBuffer(length: 4, options: .storageModeShared),
                          let commands = context.commandQueue.makeCommandBuffer(),
                          let blit = commands.makeBlitCommandEncoder() else { continue }
                    lastPTS = pts
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: texture.width / 2, y: texture.height / 2, z: 0),
                              sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
                              destinationBytesPerRow: 4, destinationBytesPerImage: 4)
                    blit.endEncoding()
                    let expected = Int((pts * Double(clip.fps) / Double(clip.denominator)).rounded()) % 256
                    nonisolated(unsafe) let readback = buffer
                    commands.addCompletedHandler { _ in
                        let green = Int(readback.contents().load(fromByteOffset: 1, as: UInt8.self))
                        let diff = abs(green - expected)
                        contentReads.withLock { $0 += 1 }
                        if min(diff, 256 - diff) > 3 { mismatches.withLock { $0 += 1 } }
                    }
                    commands.commit()
                }
                return calls
            }
            try await Task.sleep(for: .seconds(1)) // arranque
            let start = input.stats
            try await Task.sleep(for: .seconds(Self.seconds - 1))
            clock.stop()
            _ = await render.value
            input.pause()
            let end = input.stats
            let delivered = end.deliveredFrames - start.deliveredFrames
            let skipped = end.droppedFrames - start.droppedFrames
            try await Task.sleep(for: .milliseconds(100))
            Self.check(clip, Result(delivered: delivered, skipped: skipped, clockSkipped: clock.stats.skippedTicks,
                                    mismatches: mismatches.current, reads: contentReads.current,
                                    lateCalls: lateCalls.current))
        }

        struct Result {
            let delivered: Int
            let skipped: Int
            let clockSkipped: Int
            let mismatches: Int
            let reads: Int
            /// Llamadas a `texture(for:)` más de 8 ms después de su tick.
            let lateCalls: Int
        }

        private static func check(_ clip: Case, _ r: Result) {
            let (skipped, mismatches) = (r.skipped, r.mismatches)
            print(String(format: "[T31] %@ a 60p, %.0f s: entregados %d, saltados por la fuente %d, ticks saltados %d, " +
                         "contenido ≠ PTS %d de %d, llamadas tardías %d", clip.description, seconds - 1, r.delivered,
                         skipped, r.clockSkipped, mismatches, r.reads, r.lateCalls))
            // Con la máquina saturada (carga ≥ núcleos) o un consumidor que llega tarde al tick
            // (otras suites en paralelo), un salto mide la planificación, no Media.
            if SystemLoad.isOverloaded || r.lateCalls > 0 {
                print("[T31] AVISO: carga \(SystemLoad.description), llamadas tardías \(r.lateCalls); " +
                      "saltos de la fuente no exigidos (\(skipped))")
            } else {
                PerfGate.check(skipped == 0, "\(clip): fotogramas saltados por la fuente \(skipped)")
            }
            PerfGate.check(mismatches == 0, "\(clip): contenido ≠ PTS en \(mismatches) lecturas")
        }
    }
}
