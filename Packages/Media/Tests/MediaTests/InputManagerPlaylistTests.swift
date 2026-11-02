import Core
import CoreMocks
import Foundation
import Metal
import Testing
@testable import Media

/// Fuente falsa que ocupa varios decodificadores (como una playlist que precarga vídeo).
final class MultiDecoderSource: FrameSource, DecodingControllable, VideoDecoderCounting {
    let id: InputID
    let events = AsyncStream<SourceEvent> { _ in }
    let activeVideoDecoderCount: Int
    private let enabled = LockedState(false)

    init(id: InputID, decoders: Int) {
        self.id = id
        activeVideoDecoderCount = decoders
    }

    var usesVideoDecoder: Bool { true }
    var isEnabled: Bool { enabled.current }
    var nativeSize: PixelSize { .hd1080 }
    var playbackState: PlaybackState { .idle }
    func setDecodingEnabled(_ newValue: Bool) { enabled.withLock { $0 = newValue } }
    func prepare() async throws {}
    func texture(for time: HostTime) -> MTLTexture? { nil }
    func play() {}
    func pause() {}
    func seek(to seconds: Double) async {}
}

extension MediaSerialTests {
    /// Edición en directo de playlists a través de `InputManager` (con playlists de colores).
    @Suite(.enabled(if: GPU.available), .timeLimit(.minutes(1)))
    struct InputManagerPlaylistTests {
        typealias Kit = PlaylistTesting

        /// Gestor cuyas playlists no siguen al reloj (los tests dan los ticks con `ManualDriver`).
        private func manager(environment: PlaylistEnvironment = Kit.environment()) -> InputManager {
            InputManager(context: GPU.context!, playlistFactory: { d in
                guard case .playlist(let playlist) = d.content else { throw MediaError.unsupported("no es playlist") }
                return try PlaylistInput(id: d.id, playlist: playlist, environment: environment, fit: d.fit,
                                         drivenByClock: false)
            })
        }

        /// Punto 1: editar una playlist la actualiza en su sitio; no vuelve al primer item.
        @Test func editingAPlaylistUpdatesItInPlace() async throws {
            let items = Kit.colors([Kit.red, Kit.green, Kit.blue], seconds: 5)
            var descriptor = InputDescriptor(name: "p", content: .playlist(Playlist(items: items)))
            let manager = manager()
            try await manager.add(descriptor)
            let input = try #require(manager.frameSource(for: descriptor.id) as? PlaylistInput)
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            input.jump(to: items[1].id)
            await driver.run(10)
            #expect(input.currentItemID == items[1].id)

            let extra = PlaylistItem(source: .color(.black), duration: 2)
            descriptor.content = .playlist(Playlist(items: items + [extra]))
            try await manager.update(descriptor)
            await input.settle()
            #expect(manager.frameSource(for: descriptor.id) === input)
            #expect(input.playlist.items.count == 4)
            await driver.run(10)
            #expect(input.currentItemID == items[1].id) // sigue en el item 2
            #expect(input.playbackState == .playing)
        }

        /// Punto 2: el `fit` del descriptor llega a `itemFit`, en el alta y al editar.
        @Test func fitIsForwardedToItemFit() async throws {
            var descriptor = InputDescriptor(name: "p", content: .playlist(Playlist(items: Kit.colors([Kit.red]))),
                                             fit: .fill)
            let manager = InputManager(context: GPU.context!, playlistFactory: { d in
                guard case .playlist(let playlist) = d.content else { throw MediaError.unsupported("no es playlist") }
                // Fábrica que no pasa el fit: lo aplica InputManager.
                return try PlaylistInput(id: d.id, playlist: playlist, environment: Kit.environment(), drivenByClock: false)
            })
            try await manager.add(descriptor)
            let input = try #require(manager.frameSource(for: descriptor.id) as? PlaylistInput)
            #expect(input.itemFit == .fill)
            descriptor.fit = .stretch
            try await manager.update(descriptor)
            #expect(input.itemFit == .stretch)
            #expect(manager.frameSource(for: descriptor.id) === input)
        }

        /// Punto 3: al quitar o sustituir una playlist se desmonta (sus items quedan parados).
        @Test func removingOrReplacingTearsDownThePlaylist() async throws {
            let created = LockedState([FakeDecoderSource]())
            let base = Kit.environment()
            let environment = base.with(itemFactory: { _, _ in
                let source = FakeDecoderSource(id: InputID())
                created.withLock { $0.append(source) }
                return source
            })
            let manager = manager(environment: environment)
            let first = InputDescriptor(name: "a", content: .playlist(Playlist(items: Kit.colors([Kit.red, Kit.green]))))
            try await manager.add(first)
            let input = try #require(manager.frameSource(for: first.id) as? PlaylistInput)
            var driver = ManualDriver(input)
            input.play()
            await input.settle()
            await driver.run(5)
            #expect(created.current.contains { $0.playbackState == .playing })

            // Sustitución por otro tipo de entrada: la playlist anterior se desmonta.
            var replaced = first
            replaced.content = .color(.black)
            try await manager.update(replaced)
            #expect(manager.frameSource(for: first.id) is ColorInput)
            #expect(created.current.allSatisfy { $0.playbackState != .playing && !$0.isEnabled })

            // Quitar otra playlist: también se desmonta.
            let second = InputDescriptor(name: "b", content: .playlist(Playlist(items: Kit.colors([Kit.blue]))))
            try await manager.add(second)
            let other = try #require(manager.frameSource(for: second.id) as? PlaylistInput)
            var otherDriver = ManualDriver(other)
            other.play()
            await other.settle()
            await otherDriver.run(5)
            await manager.remove(second.id)
            #expect(created.current.allSatisfy { $0.playbackState != .playing && !$0.isEnabled })
        }

        /// Punto 4: una fuente que ocupa 2 decodificadores cuenta 2 para el límite de 4.
        @Test func multiDecoderSourcesCountTowardsTheCap() async throws {
            let sources = LockedState([InputID: MultiDecoderSource]())
            let costs = LockedState([InputID: Int]())
            let manager = InputManager(context: GPU.context!, playlistFactory: { d in
                let source = MultiDecoderSource(id: d.id, decoders: costs.current[d.id] ?? 1)
                sources.withLock { $0[d.id] = source }
                return source
            })
            let ids = (0..<4).map { _ in InputID() }
            costs.withLock { $0 = [ids[0]: 2, ids[1]: 1, ids[2]: 1, ids[3]: 1] }
            for (i, id) in ids.enumerated() {
                try await manager.add(InputDescriptor(id: id, name: "p\(i)", content: .playlist(Playlist())))
            }
            await manager.visibilityApplied()
            // 2 (playlist que precarga) + 1 + 1 = 4: la cuarta no decodifica.
            #expect(manager.activeDecoderIDs == [ids[0], ids[1], ids[2]])
            #expect(sources.current[ids[3]]?.isEnabled == false)
        }

        /// `PlaylistInput` informa de 2 decodificadores mientras precarga el siguiente vídeo.
        @Test func playlistReportsTwoDecodersWhilePreloading() async throws {
            let base = Kit.environment(preloadLead: 3)
            let environment = base.with(itemFactory: { _, _ in FakeDecoderSource(id: InputID()) })
            let items = ["/a.mov", "/b.mov", "/c.mov"].map {
                PlaylistItem(source: .video(MediaReference(path: $0)), duration: 2)
            }
            let input = try PlaylistInput(playlist: Playlist(items: items), environment: environment, drivenByClock: false)
            try await input.prepare()
            #expect(input.activeVideoDecoderCount >= 1)
            var driver = ManualDriver(input)
            input.play()
            await input.settle()
            var maxCount = input.activeVideoDecoderCount
            await driver.run(30) { _, _ in maxCount = max(maxCount, input.activeVideoDecoderCount) }
            #expect(maxCount == 2) // actual + siguiente precargado
            input.teardown()
        }
    }
}
