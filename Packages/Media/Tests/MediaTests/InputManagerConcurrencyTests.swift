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
    private let toggleDelay: TimeInterval

    init(id: InputID, prepareDelay: Duration = .zero, toggleDelay: TimeInterval = 0) {
        self.id = id
        self.prepareDelay = prepareDelay
        self.toggleDelay = toggleDelay
        events = AsyncStream { _ in }
    }

    var usesVideoDecoder: Bool { true }
    var isEnabled: Bool { enabled.current }
    var nativeSize: PixelSize { .hd1080 }
    var playbackState: PlaybackState { state.current }

    func setDecodingEnabled(_ newValue: Bool) {
        if toggleDelay > 0 { Thread.sleep(forTimeInterval: toggleDelay) } // AVPlayer lento
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
            await manager.visibilityApplied()
            let expected: Set<InputID> = [ids[0], ids[2], ids[3], ids[5]] // primeros 4 por orden de alta
            #expect(manager.activeDecoderIDs == expected)
            let enabled = Set(sources.current.filter { $0.value.isEnabled }.map(\.key))
            #expect(enabled == expected)
            #expect(FakeDecoderSource.counter.current.maxEnabled <= 4)
            for id in ids { await manager.remove(id) }
        }

        /// N2: aplicar la visibilidad (lenta en AVFoundation) no bloquea `frameSource(for:)`.
        @Test func frameSourceDoesNotWaitForVisibilityApplication() async throws {
            let manager = InputManager(context: context, playlistFactory: { d in
                FakeDecoderSource(id: d.id, toggleDelay: 0.1)
            })
            let ids = (0..<4).map { _ in InputID() }
            for (i, id) in ids.enumerated() {
                try await manager.add(InputDescriptor(id: id, name: "p\(i)", content: .playlist(Playlist())))
            }
            await manager.visibilityApplied()
            let clock = ContinuousClock()
            let setStart = clock.now
            manager.setVisible([ids[0]]) // 3 fuentes × 100 ms en la cola
            let setDuration = clock.now - setStart
            var worst = Duration.zero
            for _ in 0..<50 {
                let t0 = clock.now
                _ = manager.frameSource(for: ids[1])
                worst = max(worst, clock.now - t0)
                try await Task.sleep(for: .milliseconds(4))
            }
            print("[T32] setVisible \(setDuration), frameSource(for:) peor \(worst) mientras se aplica")
            #expect(setDuration < .milliseconds(20))
            #expect(worst < .milliseconds(20))
            await manager.visibilityApplied()
            #expect(manager.activeDecoderIDs == [ids[0]])
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
            await #expect(throws: MediaError.cancelled(d.id.description)) { try await adding.value }
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
