import Core
import CoreMocks
import Foundation
import Metal
@testable import MiniMixUI

/// Fuente controlable: eventos y posición a mano, sin GPU.
class TestFrameSource: FrameSource, @unchecked Sendable {
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

/// Fuente de playlist «real» controlable (estado de su secuenciador a mano).
final class TestPlaylistSource: TestFrameSource, PlaylistSourceControlling, @unchecked Sendable {
    struct Live {
        var state: SequencerState = .idle
        var current: ItemID?
        var upcoming: ItemID?
        var fit: FitMode = .fit
        var calls: [String] = []
        var playlist: Playlist?
    }

    let live = Locked(Live())

    override func play() { live.withLock { $0.calls.append("play") } }
    override func pause() { live.withLock { $0.calls.append("pause") } }
    func next() { live.withLock { $0.calls.append("next") } }
    func previous() { live.withLock { $0.calls.append("previous") } }
    func jump(to item: ItemID) { live.withLock { $0.calls.append("jump") } }
    func restartItem() { live.withLock { $0.calls.append("restart") } }
    func update(playlist: Playlist) { live.withLock { $0.playlist = playlist } }
    var sequencerState: SequencerState { live.current.state }
    var currentItemID: ItemID? { live.current.current }
    var upcomingItemID: ItemID? { live.current.upcoming }
    var itemRemainingTime: Double? { nil }
    var playlistRemainingTime: Double? { nil }
    var itemFit: FitMode {
        get { live.current.fit }
        set { live.withLock { $0.fit = newValue } }
    }
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
    /// Retardo de `update` (ediciones en vuelo) y error que lanza, si alguno.
    let updateDelay: Duration?
    let updateError: (any Error & Sendable)?

    init(replaceOnUpdate: Bool = false, updateDelay: Duration? = nil, updateError: (any Error & Sendable)? = nil) {
        self.replaceOnUpdate = replaceOnUpdate
        self.updateDelay = updateDelay
        self.updateError = updateError
    }

    /// Orden de llamadas (`update:<id>` / `remove:<id>`).
    let calls = Locked([String]())

    func add(_ descriptor: InputDescriptor) async throws {
        log.withLock { $0.adds.append(descriptor.id) }
        let source = descriptor.kind == .playlist ? TestPlaylistSource(id: descriptor.id) : TestFrameSource(id: descriptor.id)
        sources.withLock { $0[descriptor.id] = source }
    }

    func remove(_ id: InputID) async {
        calls.withLock { $0.append("remove") }
        log.withLock { $0.removes.append(id) }
        sources.withLock { $0[id] = nil }
    }

    func update(_ descriptor: InputDescriptor) async throws {
        if let updateDelay { try? await Task.sleep(for: updateDelay) }
        if let updateError { throw updateError }
        calls.withLock { $0.append("update") }
        log.withLock { $0.updates.append(descriptor) }
        // Como `InputManager` (C · PR #18): la playlist se edita en sitio y recibe el encaje.
        if let playlist = descriptor.content.playlist, let live = testSource(descriptor.id) as? TestPlaylistSource {
            live.update(playlist: playlist)
            live.itemFit = descriptor.fit
        }
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
        activeDisplay = displays.first { "UUID-\($0.id)" == uuid }?.id
    }

    var isAwaitingDisplay: Bool { selectedDisplayUUID != nil && activeDisplay == nil }
}

/// Espera (sondeo corto) a que se cumpla una condición en el MainActor.
@MainActor
func eventually(timeout: Double = 2, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<Int(timeout * 200) {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
