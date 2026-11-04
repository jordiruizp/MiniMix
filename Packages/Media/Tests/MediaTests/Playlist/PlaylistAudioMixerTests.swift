import AVFAudio
import Core
import CoreMocks
import Foundation
import Testing
@testable import Media

/// Nodos de audio de los items (revisión M2): se separan al destruir la playlist y siguen
/// al mezclador si E lo vuelve a adjuntar a otro motor.
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(1)))
    struct PlaylistAudioMixerTests {
        typealias Kit = PlaylistTesting

        private func audioPlaylist() async throws -> Playlist {
            let url = try await TestMediaFactory.shared.audio(.wav, seconds: 2)
            return Playlist(items: [PlaylistItem(source: .audio(MediaReference(path: url.path))),
                                    PlaylistItem(source: .audio(MediaReference(path: url.path)))])
        }

        private func playerNodes(_ engine: AVAudioEngine) -> Int {
            engine.attachedNodes.filter { $0 is AVAudioPlayerNode }.count
        }

        @Test func releasingPlaylistDetachesItemNodes() async throws {
            let engine = AVAudioEngine()
            var input: PlaylistInput? = try PlaylistInput(playlist: try await audioPlaylist(),
                                                          environment: Kit.environment(), drivenByClock: false)
            let node = try #require(input?.node)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            try await input?.prepare()
            var driver = ManualDriver(input!)
            await driver.run(1)
            input?.play()
            await driver.run(5)
            #expect(playerNodes(engine) >= 1)
            #expect(input!.mixer.isConnected(try #require((input!.state.withLock { $0.active?.source } as? AudioSource)?.node)))
            // Soltar todas las referencias (la del driver incluida): deinit separa los nodos.
            driver = ManualDriver(try PlaylistInput(playlist: Playlist(), environment: Kit.environment(), drivenByClock: false))
            input = nil
            for _ in 0..<100 where playerNodes(engine) > 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(playerNodes(engine) == 0)
        }

        @Test func itemNodesFollowMixerToAnotherEngine() async throws {
            let first = AVAudioEngine()
            let input = try PlaylistInput(playlist: try await audioPlaylist(), environment: Kit.environment(),
                                          drivenByClock: false)
            let node = try #require(input.node)
            first.attach(node)
            first.connect(node, to: first.mainMixerNode, format: nil)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(2)
            let item = try #require((input.state.withLock { $0.active?.source } as? AudioSource)?.node)
            #expect(item.engine === first)
            first.disconnectNodeOutput(node)
            first.detach(node)
            let second = AVAudioEngine()
            second.attach(node)
            second.connect(node, to: second.mainMixerNode, format: nil)
            await driver.run(2)
            #expect(item.engine === second)
            #expect(input.mixer.isConnected(item))
            input.teardown()
            await input.settle()
            try await Task.sleep(for: .milliseconds(60))
            #expect(item.engine == nil)
            #expect(input.mixer.ownedCount == 0)
        }

        /// Revisión M2 (#18): desmontar una playlist sonando hace rampa, cancela cargas y no deja
        /// nada tardío (ni carga, ni conexión, ni play).
        @Test func teardownRampsCancelsAndStaysDown() async throws {
            let engine = AVAudioEngine()
            let input = try PlaylistInput(playlist: try await audioPlaylist(),
                                          environment: Kit.environment(preloadLead: 10), drivenByClock: false)
            let node = try #require(input.node)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            // Precarga del siguiente en curso (sin esperar a que termine) y desmontaje inmediato.
            input.tick(HostTime(seconds: driver.time.seconds + 1 / 60.0))
            let item = try #require((input.state.withLock { $0.active?.source } as? AudioSource)?.node as? AVAudioMixing)
            #expect(item.volume == 1)
            input.teardown()
            // Se muestrea el volumen durante la rampa: debe pasar por valores intermedios.
            var samples: [Float] = []
            for _ in 0..<40 {
                samples.append(item.volume)
                try await Task.sleep(for: .milliseconds(1))
            }
            try await Task.sleep(for: .milliseconds(40))
            #expect(samples.contains { $0 > 0 && $0 < 1 }, "rampa \(samples)")
            #expect((item as? AVAudioNode)?.engine == nil)
            #expect(input.loadTasks.withLock { $0.isEmpty })
            let sources = input.state.withLock { s in [s.active, s.standby].compactMap { $0?.source } }
            #expect(sources.allSatisfy { $0.playbackState != .playing })
            // Nada posterior vuelve a cargar, conectar ni reproducir.
            let created = input.stats.createdItems
            input.play()
            input.next()
            await driver.run(30)
            #expect(input.stats.createdItems == created)
            #expect(input.mixer.ownedCount == 0)
            #expect(sources.allSatisfy { $0.playbackState != .playing })
        }
    }
}
