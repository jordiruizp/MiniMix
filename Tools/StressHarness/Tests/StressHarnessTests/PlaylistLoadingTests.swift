import Core
import CoreMocks
import Foundation
import Metal
import Testing
@testable import StressHarnessKit

/// Compuerta que abre el test: mientras está cerrada, `wait()` no vuelve (ni aunque cancelen la tarea),
/// así las cargas siguen «en vuelo» de forma determinista, sin depender de retardos ni de la carga.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool) { self.open = open }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if open { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// Fuente cuya preparación espera a la compuerta: permite ver cargas en vuelo y desalojos.
final class SlowSource: FrameSource, @unchecked Sendable {
    let id: InputID
    let nativeSize = PixelSize(width: 16, height: 16)
    let events: AsyncStream<SourceEvent> = AsyncStream { _ in }
    private let gate: Gate
    private let lock = NSLock()
    private var state = PlaybackState.idle

    init(id: InputID, gate: Gate) {
        self.id = id
        self.gate = gate
    }

    func prepare() async throws { await gate.wait() }
    func texture(for time: HostTime) -> MTLTexture? { nil }
    func play() { set(.playing) }
    func pause() { set(.paused) }
    func seek(to seconds: Double) async {}
    var playbackState: PlaybackState { lock.withLock { state } }
    private func set(_ value: PlaybackState) { lock.withLock { state = value } }
}

/// Fábrica de playlist con fuentes que esperan a la compuerta y recuerda todas las fuentes creadas.
final class SlowFactory: PipelineFactory, @unchecked Sendable {
    let name = "slow"
    let device: MTLDevice? = nil
    let components: [String: String] = [:]
    let gate: Gate
    private let lock = NSLock()
    private var made: [SlowSource] = []

    init(gate: Gate) { self.gate = gate }

    var created: [SlowSource] { lock.withLock { made } }
    func makeClock(frameRate: FrameRate) -> MasterClockProtocol { MockClock(frameRate: frameRate) }
    func makeCompositor() -> Compositing? { nil }
    func makeSwitcher() -> any SwitcherStateMachine { SwitcherState() }
    func makeSequencer(_ playlist: Playlist) -> any PlaylistSequencing { PlaylistSequencer(playlist: playlist) }
    func makeSource(id: InputID, content: InputContent, canvas: PixelSize) -> FrameSource {
        let source = SlowSource(id: id, gate: gate)
        lock.withLock { made.append(source) }
        return source
    }
}

/// Pruebas de corrección (no de rendimiento): las esperas sondean con márgenes amplios para las VMs de CI.
@Suite("PlaylistLoading", .serialized)
struct PlaylistLoadingTests {
    @Test func countsInFlightLoadsAndPausesEvictedSources() async throws {
        let gate = Gate(open: false)
        let factory = SlowFactory(gate: gate)
        let state = PlaylistState(items: 10, itemSeconds: 0.01, loop: true, factory: factory,
                                  canvas: PixelSize(width: 16, height: 16))
        #expect(state.start() == 1)
        #expect(state.liveSources == 2)
        // Con la compuerta cerrada ninguna carga termina: al avanzar, las desalojadas siguen vivas.
        var step = 0
        while state.maxLoaded < 3, step < 20 {
            step += 1
            _ = state.advance(elapsed: Double(step) * 0.02)
        }
        #expect(state.maxLoaded >= 3, "las preparaciones en vuelo cuentan: \(state.maxLoaded)")
        #expect(state.liveSources >= 3)
        gate.release()
        await state.waitUntilLoaded(timeout: .seconds(10))
        // Las cargas canceladas terminan al abrir la compuerta y se liberan.
        let deadline = ContinuousClock.now + .seconds(10)
        while state.liveSources > 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(state.liveSources == 2)
        state.tearDown()
        #expect(state.liveSources == 0)
        let sources = factory.created
        #expect(sources.count >= 3)
        #expect(sources.allSatisfy { $0.playbackState != .playing }, "toda fuente liberada queda en pausa")
    }

    @Test func fastLoadsNeverExceedTwoLiveItems() async throws {
        let factory = SlowFactory(gate: Gate(open: true))
        let state = PlaylistState(items: 5, itemSeconds: 0.01, loop: true, factory: factory,
                                  canvas: PixelSize(width: 16, height: 16))
        _ = state.start()
        for step in 1...12 {
            await state.waitUntilLoaded(timeout: .seconds(10))
            _ = state.advance(elapsed: Double(step) * 0.02)
        }
        await state.waitUntilLoaded(timeout: .seconds(10))
        #expect(state.maxLoaded == 2)
        state.tearDown()
    }
}
