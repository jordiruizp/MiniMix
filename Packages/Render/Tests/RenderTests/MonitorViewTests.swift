import AppKit
import CoreGraphics
import Foundation
import MetalKit
import SwiftUI
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

    @Test func usePreparesTheViewPixelFormat() throws {
        let renderer = try MonitorRenderer(context: GPU.context) // solo BGRA8
        let view = MTKView(frame: .zero, device: GPU.context.device)
        MonitorView.configure(view)
        view.colorPixelFormat = .rgba16Float
        let coordinator = MonitorView.Coordinator(feed: MonitorFeed(), renderer: nil)
        coordinator.use(renderer: renderer, in: view)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        let target = try #require(GPU.context.device.makeTexture(descriptor: desc))
        GPU.run { renderer.encode(nil, into: target, border: nil, commandBuffer: $0) }
        #expect(renderer.missingPipelineFrames == 0)
    }

    private func offscreenWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 90), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func restoresContentsScaleOnBackingChange() throws {
        let window = offscreenWindow()
        let view = MonitorMTKView(frame: CGRect(x: 0, y: 0, width: 160, height: 90), device: GPU.context.device)
        MonitorView.configure(view)
        window.contentView = view
        let layer = try #require(view.layer)
        #expect(layer.contentsScale == window.backingScaleFactor)

        // Estado roto observado al pasar de 2× a 1× dentro de NSHostingView.
        layer.contentsScale = 0
        view.viewDidChangeBackingProperties()
        #expect(layer.contentsScale == window.backingScaleFactor)
        #expect(view.needsDisplay)
    }

    @Test func restoresContentsScaleWhenMovedToAnotherWindow() throws {
        let view = MonitorMTKView(frame: CGRect(x: 0, y: 0, width: 160, height: 90), device: GPU.context.device)
        MonitorView.configure(view)
        let first = offscreenWindow()
        first.contentView = view
        let layer = try #require(view.layer)
        layer.contentsScale = 0
        first.contentView = nil
        let second = offscreenWindow()
        second.contentView = view
        #expect(layer.contentsScale == second.backingScaleFactor)
    }

    /// Opt-in (MINIMIX_MANUAL_OUTPUT=1): mueve una ventana real entre dos pantallas de
    /// escala distinta y comprueba que la capa sigue la escala de la pantalla destino.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINIMIX_MANUAL_OUTPUT"] == "1"))
    func movesBetweenScreensOfDifferentScale() async throws {
        _ = NSApplication.shared
        let screens = NSScreen.screens
        guard let from = screens.first,
              let target = screens.first(where: { $0.backingScaleFactor != from.backingScaleFactor }) else {
            print("[MonitorMTKView] no hay dos pantallas con escala distinta; se omite")
            return
        }
        let window = NSWindow(contentRect: CGRect(x: from.visibleFrame.minX + 40, y: from.visibleFrame.minY + 40,
                                                  width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MonitorView(feed: MonitorFeed(), context: GPU.context))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))

        window.setFrameOrigin(CGPoint(x: target.visibleFrame.minX + 40, y: target.visibleFrame.minY + 40))
        try await Task.sleep(for: .milliseconds(500))
        let metalView = try #require(Self.findMTKView(in: host))
        print("[MonitorMTKView] \(from.localizedName) \(from.backingScaleFactor)x → \(target.localizedName) "
              + "\(target.backingScaleFactor)x: contentsScale \(metalView.layer?.contentsScale ?? -1)")
        #expect(window.backingScaleFactor == target.backingScaleFactor)
        #expect(metalView.layer?.contentsScale == target.backingScaleFactor)
    }

    private static func findMTKView(in view: NSView) -> MTKView? {
        if let mtk = view as? MTKView { return mtk }
        for subview in view.subviews {
            if let found = findMTKView(in: subview) { return found }
        }
        return nil
    }
}
