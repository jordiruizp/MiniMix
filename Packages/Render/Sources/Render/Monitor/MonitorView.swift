import AppKit
import Core
import Metal
import MetalKit
import SwiftUI

/// Monitor (Preview/Programa) basado en `MTKView`: muestra la textura de un
/// `MonitorFeed` con letterbox y un borde opcional (el color lo decide la UI:
/// verde PVW, rojo PGM). Dibuja solo cuando el feed recibe un fotograma.
public struct MonitorView: NSViewRepresentable {
    public var feed: MonitorFeed
    public var context: MetalContext
    public var borderColor: RGBAColor?
    /// Ancho del borde en puntos.
    public var borderWidth: CGFloat

    public init(feed: MonitorFeed, context: MetalContext, borderColor: RGBAColor? = nil, borderWidth: CGFloat = 3) {
        self.feed = feed
        self.context = context
        self.borderColor = borderColor
        self.borderWidth = borderWidth
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(feed: feed, renderer: try? MonitorRenderer(context: context))
    }

    public func makeNSView(context ctx: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.device)
        Self.configure(view)
        view.delegate = ctx.coordinator
        ctx.coordinator.attach(view: view)
        apply(to: ctx.coordinator)
        return view
    }

    public func updateNSView(_ view: MTKView, context ctx: Context) {
        if ctx.coordinator.feed !== feed {
            ctx.coordinator.detach()
            ctx.coordinator.feed = feed
            ctx.coordinator.attach(view: view)
        }
        apply(to: ctx.coordinator)
        view.needsDisplay = true
    }

    public static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.detach()
        view.delegate = nil
    }

    /// Configuración del `MTKView`: BGRA8 sin conversión, dibujo bajo demanda y
    /// espacio de color sRGB (los valores del lienzo se tratan como sRGB codificado;
    /// el espacio de `RGBAColor` está pendiente de decisión, PC2).
    static func configure(_ view: MTKView) {
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
    }

    private func apply(to coordinator: Coordinator) {
        coordinator.borderColor = borderColor
        coordinator.borderWidth = borderWidth
    }

    /// Delegado del `MTKView`: codifica el monitor en el drawable y lo presenta.
    @MainActor
    public final class Coordinator: NSObject, MTKViewDelegate {
        var feed: MonitorFeed
        let renderer: MonitorRenderer?
        var borderColor: RGBAColor?
        var borderWidth: CGFloat = 3
        /// Registro de esta vista en `feed`; solo se da de baja a sí misma.
        private(set) var token: MonitorFeed.ObserverToken?

        init(feed: MonitorFeed, renderer: MonitorRenderer?) {
            self.feed = feed
            self.renderer = renderer
        }

        func attach(view: MTKView) {
            detach()
            let box = WeakViewBox(view)
            token = feed.addObserver {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { box.view?.needsDisplay = true }
                }
            }
        }

        func detach() {
            if let token { feed.removeObserver(token) }
            token = nil
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        public func draw(in view: MTKView) {
            guard let token else { return }
            let texture = feed.takeForDrawing(token)
            guard let renderer, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return }
            commandBuffer.label = "MiniMix.Monitor"
            let scale = view.window?.backingScaleFactor ?? 2
            let border = borderColor.map { MonitorBorder(color: $0, width: Float(borderWidth * scale)) }
            renderer.encode(texture, pass: pass, border: border, commandBuffer: commandBuffer)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// Referencia débil a la vista que puede capturarse en cierres `@Sendable`;
/// solo se desreferencia en el hilo principal.
private final class WeakViewBox: @unchecked Sendable {
    weak var view: MTKView?
    init(_ view: MTKView) { self.view = view }
}
