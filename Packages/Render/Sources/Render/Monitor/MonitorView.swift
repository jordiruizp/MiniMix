import AppKit
import Core
import Metal
import MetalKit
import SwiftUI

/// Monitor (Preview/Programa) basado en `MTKView`: muestra la textura de un
/// `MonitorFeed` con letterbox y un borde opcional (el color lo decide la UI:
/// verde PVW, rojo PGM). Dibuja solo cuando el feed recibe un fotograma.
///
/// El `MonitorRenderer` se inyecta o se comparte por `MetalContext`
/// (`MonitorRenderer.shared(for:)`); si cambia el renderer/contexto, la vista
/// cambia de dispositivo sin recrearse. Sin renderer no dibuja y lo registra en el log.
public struct MonitorView: NSViewRepresentable {
    public var feed: MonitorFeed
    public var renderer: MonitorRenderer?
    public var borderColor: RGBAColor?
    /// Ancho del borde en puntos.
    public var borderWidth: CGFloat

    public init(feed: MonitorFeed, renderer: MonitorRenderer?, borderColor: RGBAColor? = nil, borderWidth: CGFloat = 3) {
        self.feed = feed
        self.renderer = renderer
        self.borderColor = borderColor
        self.borderWidth = borderWidth
    }

    /// Usa el renderer compartido de `context`.
    public init(feed: MonitorFeed, context: MetalContext, borderColor: RGBAColor? = nil, borderWidth: CGFloat = 3) {
        self.init(feed: feed, renderer: MonitorRenderer.shared(for: context), borderColor: borderColor,
                  borderWidth: borderWidth)
    }

    public var context: MetalContext? { renderer?.context }

    public func makeCoordinator() -> Coordinator {
        Coordinator(feed: feed, renderer: renderer)
    }

    public func makeNSView(context ctx: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer?.context.device)
        Self.configure(view)
        view.delegate = ctx.coordinator
        ctx.coordinator.attach(view: view)
        ctx.coordinator.use(renderer: renderer, in: view)
        apply(to: ctx.coordinator)
        return view
    }

    public func updateNSView(_ view: MTKView, context ctx: Context) {
        if ctx.coordinator.feed !== feed {
            ctx.coordinator.detach()
            ctx.coordinator.feed = feed
            ctx.coordinator.attach(view: view)
        }
        ctx.coordinator.use(renderer: renderer, in: view)
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
        private(set) var renderer: MonitorRenderer?
        private var loggedMissingRenderer = false
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

        /// Cambia de renderer (y de dispositivo si cambia el contexto).
        func use(renderer newRenderer: MonitorRenderer?, in view: MTKView) {
            if newRenderer !== renderer {
                renderer = newRenderer
                loggedMissingRenderer = false
            }
            if let device = newRenderer?.context.device, view.device !== device {
                view.device = device
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
            let lease = feed.acquireForDrawing(token)
            guard let renderer else {
                lease?.release()
                if !loggedMissingRenderer {
                    loggedMissingRenderer = true
                    renderLog.error("MonitorView: no MonitorRenderer available; monitor will stay blank")
                }
                return
            }
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else {
                lease?.release()
                return
            }
            commandBuffer.label = "MiniMix.Monitor"
            let scale = view.window?.backingScaleFactor ?? 2
            let border = borderColor.map { MonitorBorder(color: $0, width: Float(borderWidth * scale)) }
            renderer.encode(lease?.texture, pass: pass, border: border, commandBuffer: commandBuffer)
            lease?.release(after: commandBuffer)
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
