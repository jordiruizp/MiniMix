import CoreGraphics
import MetalKit
import Testing
@testable import Render

@Suite("MonitorView", .enabled(if: hasGPU))
@MainActor
struct MonitorViewTests {
    @Test func configuresSRGBOnDemandView() {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 36), device: GPU.context.device)
        MonitorView.configure(view)
        #expect(view.colorspace?.name == CGColorSpace.sRGB)
        #expect(view.colorPixelFormat == .bgra8Unorm)
        #expect(view.isPaused && view.enableSetNeedsDisplay)
    }

    @Test func coordinatorsShareFeedAndDetachOnlyThemselves() throws {
        let feed = MonitorFeed()
        let renderer = try MonitorRenderer(context: GPU.context)
        let viewA = MTKView(frame: .zero, device: GPU.context.device)
        let viewB = MTKView(frame: .zero, device: GPU.context.device)
        let coordA = MonitorView.Coordinator(feed: feed, renderer: renderer)
        let coordB = MonitorView.Coordinator(feed: feed, renderer: renderer)
        coordA.attach(view: viewA)
        coordB.attach(view: viewB)
        #expect(feed.observerCount == 2)
        // Re-attach (p. ej. updateNSView) no duplica el registro.
        coordA.attach(view: viewA)
        #expect(feed.observerCount == 2)
        MonitorView.dismantleNSView(viewA, coordinator: coordA)
        #expect(feed.observerCount == 1)
        #expect(coordB.token != nil)
        MonitorView.dismantleNSView(viewB, coordinator: coordB)
        #expect(feed.observerCount == 0)
    }

    @Test func sharedRendererPerContextAndSwitching() throws {
        let shared = try #require(MonitorRenderer.shared(for: GPU.context))
        #expect(MonitorRenderer.shared(for: GPU.context) === shared)
        #expect(MonitorView(feed: MonitorFeed(), context: GPU.context).renderer === shared)

        let otherContext = try #require(MetalContext(device: GPU.context.device))
        let other = try #require(MonitorRenderer.shared(for: otherContext))
        #expect(other !== shared)

        let view = MTKView(frame: .zero, device: nil)
        let coordinator = MonitorView.Coordinator(feed: MonitorFeed(), renderer: nil)
        coordinator.use(renderer: shared, in: view)
        #expect(coordinator.renderer === shared && view.device === GPU.context.device)
        coordinator.use(renderer: other, in: view)
        #expect(coordinator.renderer === other && view.device === otherContext.device)
        coordinator.use(renderer: nil, in: view)
        #expect(coordinator.renderer == nil)
    }

    @Test func sharedRendererCachesFailure() throws {
        let context = try #require(MetalContext(device: GPU.context.device))
        let attempts = Counter()
        struct Boom: Error {}
        for _ in 0..<3 {
            let renderer = MonitorRenderer.shared(for: context) { _ in
                attempts.increment()
                throw Boom()
            }
            #expect(renderer == nil)
        }
        #expect(attempts.value == 1)
        #expect(MonitorRenderer.shared(for: context) == nil) // sigue cacheado como fallo
    }
}
