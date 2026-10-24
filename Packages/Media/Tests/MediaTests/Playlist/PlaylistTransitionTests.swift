import AVFAudio
import Core
import CoreMocks
import Foundation
import Metal
import Testing
@testable import Media

/// T71: fundido entre items (vídeo con el Compositor, audio con `audioGains`) y visual de
/// los items de audio.
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(2)))
    struct PlaylistTransitionTests {
        typealias T = PlaylistTesting

        @Test func midFadeIsHalfMixWithinOneDeltaE() async throws {
            let items = T.colors([T.red, T.blue], seconds: 2)
            let input = try PlaylistInput(playlist: Playlist(items: items, itemTransition: .fade(seconds: 1)),
                                          environment: T.environment(), drivenByClock: false)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            // Rojo empieza en el tick de play; el fundido (60 ticks) empieza 1 s después.
            var pixels: [SIMD4<Double>] = []
            await driver.run(150) { _, texture in pixels.append(T.pixel(texture) ?? SIMD4(-1, -1, -1, -1)) }
            let expectedMid = SIMD3(0.5, 0, 0.5)
            let mid = pixels[89]
            let deltaE = T.deltaE(SIMD3(mid.x, mid.y, mid.z), expectedMid)
            print("[PL] fundido rojo→azul a mitad: \(mid) ΔE \(String(format: "%.3f", deltaE)) (fundidos codificados \(input.renderer.compositeCount))")
            #expect(deltaE < 1)
            #expect(T.isColor(pixels[57], T.red))
            #expect(T.isColor(pixels[121], T.blue))
            // Monótono: el azul crece y el rojo decrece durante el fundido.
            let fade = pixels[58...120]
            #expect(zip(fade, fade.dropFirst()).allSatisfy { $1.z >= $0.z - 0.005 && $1.x <= $0.x + 0.005 })
            // Un cuarto: mezcla = smoothstep(0,25) = 0,15625.
            let quarter = pixels[74]
            let m = TransitionCurve.videoMix(0.25)
            #expect(T.deltaE(SIMD3(quarter.x, quarter.y, quarter.z), SIMD3(1 - m, 0, m)) < 1.5)
            #expect(input.renderer.compositeCount >= 55)
            #expect(input.stats.maxLoadedItems <= 2)
            #expect(input.stats.switches == 1)
        }

        @Test func fadeAppliesEqualPowerAudioGains() async throws {
            let url = try await TestMediaFactory.shared.audio(.wav, seconds: 2)
            let items = [PlaylistItem(source: .audio(MediaReference(path: url.path))),
                         PlaylistItem(source: .audio(MediaReference(path: url.path)))]
            let input = try PlaylistInput(playlist: Playlist(items: items, itemTransition: .fade(seconds: 1)),
                                          environment: T.environment(), drivenByClock: false)
            let engine = AVAudioEngine()
            let node = try #require(input.node)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            var gains: [(Float, Float)] = []
            var visuals: [SIMD4<Double>?] = []
            await driver.run(140) { _, texture in
                let pair = input.state.withLock { s -> (Float, Float)? in
                    guard let out = (s.outgoing?.source as? AudioSource)?.node as? AVAudioMixing,
                          let incoming = (s.active?.source as? AudioSource)?.node as? AVAudioMixing else { return nil }
                    return (out.volume, incoming.volume)
                }
                if let pair { gains.append(pair) }
                visuals.append(T.pixel(texture))
            }
            // Fundido de 60 ticks: en la mitad, ganancias de igual potencia (cos/sin 45°).
            #expect(gains.count >= 58, "\(gains.count)")
            if gains.count > 30 {
                let mid = gains[30]
                print("[PL] ganancias a mitad del fundido: \(mid) (\(gains.count) ticks de fundido)")
                #expect(abs(mid.0 - Float(TransitionCurve.audioGains(30.0 / 60).outgoing)) < 0.03)
                #expect(abs(mid.1 - Float(TransitionCurve.audioGains(30.0 / 60).incoming)) < 0.03)
                #expect(gains.allSatisfy { abs($0.0 * $0.0 + $0.1 * $0.1 - 1) < 0.05 })
            }
            // audioItemVisual por defecto: negro.
            #expect(visuals.allSatisfy { T.isColor($0, .black) })
            #expect(input.stats.maxLoadedItems <= 2)
            engine.stop()
        }

        @Test(arguments: [AudioVisual.lastImage, AudioVisual.black])
        func audioItemShowsLastImageOrBlack(_ visual: AudioVisual) async throws {
            let url = try await TestMediaFactory.shared.audio(.wav, seconds: 2)
            let items = [PlaylistItem(source: .color(T.green), duration: 0.5),
                         PlaylistItem(source: .audio(MediaReference(path: url.path)))]
            let input = try PlaylistInput(playlist: Playlist(items: items, audioItemVisual: visual),
                                          environment: T.environment(), drivenByClock: false)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            var pixels: [SIMD4<Double>?] = []
            await driver.run(90) { _, texture in pixels.append(T.pixel(texture)) }
            #expect(input.currentItemID == items[1].id)
            let expected = visual == .lastImage ? T.green : RGBAColor.black
            #expect(pixels[40...].allSatisfy { T.isColor($0, expected) }, "\(visual)")
            #expect(pixels[..<28].allSatisfy { T.isColor($0, T.green) })
        }
    }
}
