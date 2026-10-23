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
}
