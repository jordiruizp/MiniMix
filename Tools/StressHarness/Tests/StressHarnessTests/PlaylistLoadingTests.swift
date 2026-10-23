import Core
import CoreMocks
import Foundation
import Metal
import Testing
@testable import StressHarnessKit

/// Fuente cuya preparación tarda: permite ver cargas en vuelo y desalojos.
final class SlowSource: FrameSource, @unchecked Sendable {
    let id: InputID
    let nativeSize = PixelSize(width: 16, height: 16)
    let events: AsyncStream<SourceEvent> = AsyncStream { _ in }
    private let delay: Duration
    private let lock = NSLock()
    private var state = PlaybackState.idle

    init(id: InputID, delay: Duration) {
        self.id = id
        self.delay = delay
    }

    func prepare() async throws { try? await Task.sleep(for: delay) }
    func texture(for time: HostTime) -> MTLTexture? { nil }
    func play() { set(.playing) }
    func pause() { set(.paused) }
    func seek(to seconds: Double) async {}
    var playbackState: PlaybackState { lock.withLock { state } }
    private func set(_ value: PlaybackState) { lock.withLock { state = value } }
}

/// Fábrica de playlist con fuentes lentas que recuerda todas las fuentes creadas.
final class SlowFactory: PipelineFactory, @unchecked Sendable {
    let name = "slow"
    let device: MTLDevice? = nil
    let components: [String: String] = [:]
    let delay: Duration
    private let lock = NSLock()
    private var made: [SlowSource] = []

    init(delay: Duration) { self.delay = delay }

    var created: [SlowSource] { lock.withLock { made } }
    func makeClock(frameRate: FrameRate) -> MasterClockProtocol { MockClock(frameRate: frameRate) }
    func makeCompositor() -> Compositing? { nil }
    func makeSwitcher() -> any SwitcherStateMachine { SwitcherState() }
    func makeSequencer(_ playlist: Playlist) -> any PlaylistSequencing { PlaylistSequencer(playlist: playlist) }
    func makeSource(id: InputID, content: InputContent, canvas: PixelSize) -> FrameSource {
        let source = SlowSource(id: id, delay: delay)
        lock.withLock { made.append(source) }
        return source
    }
}

@Suite("PlaylistLoading", .serialized)
struct PlaylistLoadingTests {
    @Test func countsInFlightLoadsAndPausesEvictedSources() async throws {
        let factory = SlowFactory(delay: .milliseconds(200))
        let state = PlaylistState(items: 10, itemSeconds: 0.01, loop: true, factory: factory,
                                  canvas: PixelSize(width: 16, height: 16))
        #expect(state.start() == 1)
        #expect(state.liveSources == 2)
        // Avanzar items mucho más deprisa de lo que se preparan: las cargas desalojadas siguen vivas.
        for step in 1...5 { _ = state.advance(elapsed: Double(step) * 0.02) }
        #expect(state.maxLoaded > 2, "las preparaciones en vuelo cuentan: \(state.maxLoaded)")
        await state.waitUntilLoaded(timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(300))
        #expect(state.liveSources == 2)
        state.tearDown()
        #expect(state.liveSources == 0)
        let sources = factory.created
        #expect(sources.count >= 6)
        #expect(sources.allSatisfy { $0.playbackState != .playing }, "toda fuente liberada queda en pausa")
    }

    @Test func fastLoadsNeverExceedTwoLiveItems() async throws {
        let factory = SlowFactory(delay: .zero)
        let state = PlaylistState(items: 5, itemSeconds: 0.01, loop: true, factory: factory,
                                  canvas: PixelSize(width: 16, height: 16))
        _ = state.start()
        for step in 1...12 {
            await state.waitUntilLoaded(timeout: .seconds(1))
            _ = state.advance(elapsed: Double(step) * 0.02)
        }
        await state.waitUntilLoaded(timeout: .seconds(1))
        #expect(state.maxLoaded == 2)
        state.tearDown()
    }
}
