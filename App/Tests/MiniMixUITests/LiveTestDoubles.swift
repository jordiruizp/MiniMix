import Core
import CoreMocks
import Foundation
import Metal
@testable import MiniMixUI

/// Fuente controlable: eventos y posición a mano, sin GPU.
final class TestFrameSource: FrameSource, @unchecked Sendable {
    let id: InputID
    let nativeSize = PixelSize(width: 16, height: 9)
    let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation
    private let position = Locked<Double?>(nil)

    init(id: InputID) {
        self.id = id
        (events, continuation) = AsyncStream.makeStream()
    }

    func emit(_ event: SourceEvent) { continuation.yield(event) }
    func setPosition(_ seconds: Double?) { position.withLock { $0 = seconds } }

    func prepare() async throws {}
    func texture(for time: HostTime) -> MTLTexture? { nil }
    func play() {}
    func pause() {}
    func seek(to seconds: Double) async {}
    var playbackState: PlaybackState { .idle }
    var currentTime: Double? { position.current }
}

/// Gestor de entradas que registra altas/bajas/updates y puede sustituir la fuente en `update`.
final class TestInputManager: InputManaging, @unchecked Sendable {
    struct Log {
        var adds: [InputID] = []
        var removes: [InputID] = []
        var updates: [InputDescriptor] = []
    }

    let log = Locked(Log())
    private let sources = Locked([InputID: TestFrameSource]())
    /// `update` crea una fuente nueva (como Media al cambiar el contenido).
    let replaceOnUpdate: Bool

    init(replaceOnUpdate: Bool = false) { self.replaceOnUpdate = replaceOnUpdate }

    func add(_ descriptor: InputDescriptor) async throws {
        log.withLock { $0.adds.append(descriptor.id) }
        let source = TestFrameSource(id: descriptor.id)
        sources.withLock { $0[descriptor.id] = source }
    }

    func remove(_ id: InputID) async {
        log.withLock { $0.removes.append(id) }
        sources.withLock { $0[id] = nil }
    }

    func update(_ descriptor: InputDescriptor) async throws {
        log.withLock { $0.updates.append(descriptor) }
        if replaceOnUpdate {
            let source = TestFrameSource(id: descriptor.id)
            sources.withLock { $0[descriptor.id] = source }
        }
    }

    func frameSource(for id: InputID) -> FrameSource? { sources.withLock { $0[id] } }
    func testSource(_ id: InputID) -> TestFrameSource? { sources.withLock { $0[id] } }
    func audioSource(for id: InputID) -> AudioSource? { nil }
    func setVisible(_ ids: Set<InputID>) {}
}

/// Salida falsa con los extras de `OutputController` (UUID elegido, App Nap).
@MainActor
final class FakeOutput: OutputPresenting, ProgramOutputControlling {
    var displays = [DisplayInfo(id: 7, name: "Proyector", size: .hd1080, isBuiltIn: false)]
    private(set) var activeDisplay: DisplayInfo.ID?
    private(set) var selectedDisplayUUID: String?
    var preventsAppNap = false
    private(set) var restoredUUIDs: [String] = []
    let displayChanges: AsyncStream<[DisplayInfo]>
    private let continuation: AsyncStream<[DisplayInfo]>.Continuation

    init() { (displayChanges, continuation) = AsyncStream.makeStream() }

    func show(on display: DisplayInfo.ID) {
        activeDisplay = display
        selectedDisplayUUID = "UUID-\(display)"
    }

    func hide() {
        activeDisplay = nil
        selectedDisplayUUID = nil
    }

    func show(displayUUID uuid: String) {
        restoredUUIDs.append(uuid)
        selectedDisplayUUID = uuid
        activeDisplay = uuid == "UUID-7" ? 7 : nil
    }

    var isAwaitingDisplay: Bool { selectedDisplayUUID != nil && activeDisplay == nil }
}

/// Espera (sondeo corto) a que se cumpla una condición en el MainActor.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
