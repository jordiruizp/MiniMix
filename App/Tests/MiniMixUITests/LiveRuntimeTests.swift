import Core
import CoreMocks
import Foundation
import Metal
@testable import MiniMixUI
import Render
import Testing

/// G-real · render y ciclo de vida con Metal real (se omite sin GPU).
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct LiveRuntimeTests {
    final class Counter: @unchecked Sendable {
        let calls = Locked(0)
    }

    private func colorSource(_ id: InputID) async throws -> MockFrameSource {
        let source = MockFrameSource(id: id, color: RGBAColor(red: 1, green: 0, blue: 0))
        try await source.prepare()
        return source
    }

    @Test func sourcesAreResolvedOnPublishNotPerFrame() async throws {
        let context = try #require(MetalContext.shared)
        let id = InputID()
        let source = try await colorSource(id)
        let counter = Counter()
        let renderer = try LiveRenderer(context: context, canvas: PixelSize(width: 32, height: 18),
                                        frameRate: .fps60) { requested in
            counter.calls.withLock { $0 += 1 }
            return requested == id ? source : nil
        }
        renderer.update(BusState(program: id))
        #expect(counter.calls.current == 1)
        for frame in 0..<5 { renderer.render(at: HostTime(seconds: Double(frame) / 60)) }
        #expect(counter.calls.current == 1, "las fuentes se cachean entre fotogramas")
        renderer.update(BusState(preview: id, program: id)) // mismo id ya resuelto
        #expect(counter.calls.current == 1)
        renderer.update(BusState(program: id), refreshSources: true)
        #expect(counter.calls.current == 2)
        #expect(renderer.cachedSourceIDs == [id])
    }

    @Test func reconfigureChangesCanvasKeepingFeeds() async throws {
        let context = try #require(MetalContext.shared)
        let renderer = try LiveRenderer(context: context, canvas: PixelSize(width: 32, height: 18),
                                        frameRate: .fps60) { _ in nil }
        let feed = renderer.programFeed
        try await waitFrame(renderer.render(at: .zero))
        #expect(feed.currentTexture?.width == 32)
        try renderer.reconfigure(canvas: PixelSize(width: 64, height: 36), frameRate: .fps25)
        #expect(renderer.frameRate == .fps25)
        try await waitFrame(renderer.render(at: HostTime(seconds: 0.04)))
        #expect(renderer.programFeed === feed)
        #expect(feed.currentTexture?.width == 64)
    }

    /// Tras reconfigurar, el pool no retiene texturas del lienzo viejo (4K→1080p fijaría cientos de MB).
    @Test func reconfigurePurgesOldSizeTextures() async throws {
        let context = try #require(MetalContext.shared)
        let renderer = try LiveRenderer(context: context, canvas: PixelSize(width: 512, height: 288),
                                        frameRate: .fps60) { _ in nil }
        let oldTexture = 512 * 288 * 4
        for frame in 0..<6 { try await waitFrame(renderer.render(at: HostTime(seconds: Double(frame) / 60))) }
        #expect(renderer.pooledBytes >= oldTexture, "el pool retiene texturas del lienzo grande")
        try renderer.reconfigure(canvas: PixelSize(width: 16, height: 9), frameRate: .fps60)
        for frame in 6..<(8 + LiveRenderer.maxFramesInFlight) {
            try await waitFrame(renderer.render(at: HostTime(seconds: Double(frame) / 60)))
        }
        #expect(renderer.pooledBytes < oldTexture, "quedan texturas viejas: \(renderer.pooledBytes) B")
    }

    /// M2/M3: stop + start no congela el render (cada arranque se suscribe a ticks nuevos).
    @Test func runtimeStopStartKeepsRendering() async throws {
        let project = Project(canvas: CanvasFormat(size: PixelSize(width: 32, height: 18), frameRate: .fps60))
        let (live, runtime) = try AppServices.live(project: project)
        var services = live
        let suite = DefaultsSuite()
        services.defaults = suite.defaults
        let app = AppViewModel(services: services)
        app.start()
        #expect(runtime.isRunning)
        #expect(await eventually { runtime.renderer.renderedFrames > 3 })
        app.stop()
        #expect(!runtime.isRunning)
        let stopped = runtime.renderer.renderedFrames
        app.start()
        #expect(await eventually { runtime.renderer.renderedFrames > stopped + 3 }, "el render siguió tras reiniciar")
        app.stop()
    }

    @Test func reconfigureFromProjectUpdatesClockAndRenderer() async throws {
        let (_, runtime) = try AppServices.live(project: Project(canvas: CanvasFormat(size: .hd720, frameRate: .fps60)))
        runtime.reconfigure(CanvasFormat(size: PixelSize(width: 640, height: 360), frameRate: .fps25))
        #expect(runtime.clock.frameRate == .fps25)
        #expect(runtime.renderer.canvas == PixelSize(width: 640, height: 360))
    }

    private func waitFrame(_ buffer: MTLCommandBuffer?) async throws {
        let buffer = try #require(buffer)
        let deadline = ContinuousClock.now + .seconds(5)
        while buffer.status != .completed, buffer.status != .error, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
