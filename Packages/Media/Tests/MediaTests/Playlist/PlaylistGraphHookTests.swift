import AVFAudio
import Core
import CoreMocks
import Foundation
import Testing
@testable import Media

/// `PlaylistEnvironment.graphChange`: todos los cambios del grafo de audio de los items pasan
/// por el hook (como `AudioEngine.performGraphChange` de E), en serie y sin reentrar.
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(1)))
    struct PlaylistGraphHookTests {
        typealias Kit = PlaylistTesting

        /// Hook falso: cuenta las llamadas, detecta reentradas/concurrencia y comprueba que el
        /// grafo no cambió fuera del hook (nodos adjuntados entre una salida y la siguiente entrada).
        final class FakeHook: @unchecked Sendable {
            let engine: AVAudioEngine
            private let lock = NSLock()
            private(set) var calls = 0
            private(set) var reentries = 0
            private(set) var outsideChanges = 0
            private var depth = 0
            private var lastNodeCount: Int

            init(engine: AVAudioEngine) {
                self.engine = engine
                lastNodeCount = engine.attachedNodes.count
            }

            func run(_ change: @escaping () -> Void) {
                lock.lock()
                depth += 1
                if depth > 1 { reentries += 1 }
                calls += 1
                if engine.attachedNodes.count != lastNodeCount { outsideChanges += 1 }
                change()
                lastNodeCount = engine.attachedNodes.count
                depth -= 1
                lock.unlock()
            }

            var playerNodes: Int { engine.attachedNodes.filter { $0 is AVAudioPlayerNode }.count }
        }

        @Test func everyGraphChangeGoesThroughTheHook() async throws {
            let engine = AVAudioEngine()
            let hook = FakeHook(engine: engine)
            let url = try await TestMediaFactory.shared.audio(.wav, seconds: 2)
            let items = [PlaylistItem(source: .audio(MediaReference(path: url.path))),
                         PlaylistItem(source: .audio(MediaReference(path: url.path)))]
            var environment = Kit.environment()
            environment.graphChange = { change in hook.run(change) }
            let input = try PlaylistInput(playlist: Playlist(items: items, itemTransition: .fade(seconds: 0.5)),
                                          environment: environment, drivenByClock: false)
            let node = try #require(input.node)
            hook.run {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: nil)
            }
            let before = hook.calls
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            // Dos items (fundido incluido) y el final: conexión, precarga y liberación.
            await driver.run(60 * 4)
            #expect(hook.calls > before)
            #expect(hook.playerNodes >= 1)
            input.teardown()
            await input.settle()
            try await Task.sleep(for: .milliseconds(60))
            #expect(hook.playerNodes == 0)
            #expect(hook.reentries == 0)
            #expect(hook.outsideChanges == 0, "cambios del grafo fuera del hook: \(hook.outsideChanges)")
            print("[PL] cambios de grafo por el hook: \(hook.calls)")
        }

        @Test func noHookKeepsDirectBehaviour() async throws {
            let engine = AVAudioEngine()
            let url = try await TestMediaFactory.shared.audio(.wav, seconds: 2)
            let input = try PlaylistInput(playlist: Playlist(items: [PlaylistItem(source: .audio(MediaReference(path: url.path)))]),
                                          environment: Kit.environment(), drivenByClock: false)
            let node = try #require(input.node)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(2)
            let item = try #require((input.state.withLock { $0.active?.source } as? AudioSource)?.node)
            #expect(input.mixer.isConnected(item))
        }
    }
}
