import Core
import CoreMocks
import Foundation
import Metal
import Render
import Testing
@testable import Media

/// Fuente falsa con «decodificador»: cuenta cuántas hay habilitadas a la vez.
final class FakeDecoderSource: FrameSource, DecodingControllable {
    static let counter = LockedState((enabled: 0, maxEnabled: 0))

    let id: InputID
    let events: AsyncStream<SourceEvent>
    private let enabled = LockedState(false)
    private let state = LockedState(PlaybackState.idle)
    private let prepareDelay: Duration

    init(id: InputID, prepareDelay: Duration = .zero) {
        self.id = id
        self.prepareDelay = prepareDelay
        events = AsyncStream { _ in }
    }

    var usesVideoDecoder: Bool { true }
    var isEnabled: Bool { enabled.current }
    var nativeSize: PixelSize { .hd1080 }
    var playbackState: PlaybackState { state.current }

    func setDecodingEnabled(_ newValue: Bool) {
        let changed = enabled.withLock { value -> Bool in
            defer { value = newValue }
            return value != newValue
        }
        guard changed else { return }
        Self.counter.withLock { c in
            c.enabled += newValue ? 1 : -1
            c.maxEnabled = max(c.maxEnabled, c.enabled)
        }
    }

    func prepare() async throws { try await Task.sleep(for: prepareDelay) }
    func texture(for time: HostTime) -> MTLTexture? { nil }
    func play() { state.withLock { $0 = .playing } }
    func pause() { state.withLock { $0 = .paused } }
    func seek(to seconds: Double) async {}
}

extension MediaSerialTests {
    @Suite(.enabled(if: GPU.available), .timeLimit(.minutes(1)))
    struct InputManagerConcurrencyTests {
        let context = GPU.context!

        private func playlist(_ name: String) -> InputDescriptor {
            InputDescriptor(name: name, content: .playlist(Playlist()))
        }

        /// Punto 2 de la revisión: `setVisible` concurrentes nunca superan 4
        /// decodificadores y el estado final corresponde a la última llamada.
        @Test func concurrentSetVisibleKeepsCapAndOrder() async throws {
            let sources = LockedState([InputID: FakeDecoderSource]())
            let manager = InputManager(context: context, playlistFactory: { d in
                let source = FakeDecoderSource(id: d.id)
                sources.withLock { $0[d.id] = source }
                return source
            })
            let ids = (0..<10).map { _ in InputID() }
            for (i, id) in ids.enumerated() {
                try await manager.add(InputDescriptor(id: id, name: "p\(i)", content: .playlist(Playlist())))
            }
            FakeDecoderSource.counter.withLock { $0.maxEnabled = $0.enabled }
            await withTaskGroup(of: Void.self) { group in
                for n in 0..<300 {
                    group.addTask {
                        let subset = Set(ids.enumerated().filter { ($0.offset * 7 + n) % 3 != 0 }.map(\.element))
                        manager.setVisible(subset)
                    }
                }
            }
            let final: Set<InputID> = [ids[9], ids[2], ids[5], ids[0], ids[7], ids[3]]
            manager.setVisible(final)
            let expected: Set<InputID> = [ids[0], ids[2], ids[3], ids[5]] // primeros 4 por orden de alta
            #expect(manager.activeDecoderIDs == expected)
            let enabled = Set(sources.current.filter { $0.value.isEnabled }.map(\.key))
            #expect(enabled == expected)
            #expect(FakeDecoderSource.counter.current.maxEnabled <= 4)
            for id in ids { await manager.remove(id) }
        }

        /// Punto 3: `remove` durante un `add` lo cancela; la entrada no aparece después.
        @Test func removeDuringAddDoesNotResurrect() async throws {
            let created = LockedState([FakeDecoderSource]())
            let manager = InputManager(context: context, playlistFactory: { d in
                let source = FakeDecoderSource(id: d.id, prepareDelay: .milliseconds(300))
                created.withLock { $0.append(source) }
                return source
            })
            let d = playlist("lenta")
            let adding = Task { try await manager.add(d) }
            try await Task.sleep(for: .milliseconds(50))
            await manager.remove(d.id)
            await #expect(throws: (any Error).self) { try await adding.value }
            try await Task.sleep(for: .milliseconds(400))
            #expect(manager.frameSource(for: d.id) == nil)
            #expect(manager.inputIDs.isEmpty)
            #expect(created.current.allSatisfy { !$0.isEnabled })
            // Se puede volver a dar de alta.
            try await manager.add(d)
            #expect(manager.frameSource(for: d.id) != nil)
        }

        /// Punto 3: dos `add` concurrentes del mismo id preparan una sola fuente.
        @Test func concurrentAddsPrepareOnce() async throws {
            let calls = LockedState(0)
            let manager = InputManager(context: context, playlistFactory: { d in
                calls.withLock { $0 += 1 }
                return FakeDecoderSource(id: d.id, prepareDelay: .milliseconds(100))
            })
            let d = playlist("doble")
            let first = Task { try await manager.add(d) }
            let second = Task { try await manager.add(d) }
            let results = [await first.result, await second.result]
            #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
            #expect(calls.current == 1)
            #expect(manager.inputIDs == [d.id])
        }
    }
}
