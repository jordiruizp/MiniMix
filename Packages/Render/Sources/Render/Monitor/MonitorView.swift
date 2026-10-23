import AppKit
import Core
import Metal
import MetalKit
import SwiftUI

/// Canal entre quien renderiza (cualquier hilo) y un `MonitorView`.
///
/// El render llama a `display(_:)` con la textura del lienzo de cada fotograma;
/// la vista se redibuja bajo demanda en el hilo principal (las peticiones se
/// agrupan: como máximo un redibujado pendiente). La textura no debe
/// reescribirse mientras se muestra: el productor debe rotar texturas (p. ej.
/// con `TexturePool`) en lugar de reutilizar siempre la misma.
public final class MonitorFeed: @unchecked Sendable {
    private struct State {
        var texture: MTLTexture?
        var redrawPending = false
        var invalidate: (@Sendable () -> Void)?
    }

    private let state = UnfairLocked(State())

    public init() {}

    /// Publica la textura a mostrar y pide un redibujado. Seguro desde cualquier hilo.
    public func display(_ texture: MTLTexture?) {
        let invalidate: (@Sendable () -> Void)? = state.withLock { st in
            st.texture = texture
            guard !st.redrawPending, let callback = st.invalidate else { return nil }
            st.redrawPending = true
            return callback
        }
        invalidate?()
    }

    /// Última textura publicada.
    public var currentTexture: MTLTexture? { state.withLock { $0.texture } }

    /// La vista toma la textura y libera la petición pendiente.
    func takeForDrawing() -> MTLTexture? {
        state.withLock { st in
            st.redrawPending = false
            return st.texture
        }
    }

    func setInvalidationHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { st in
            st.invalidate = handler
            st.redrawPending = false
        }
    }
}

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
            ctx.coordinator.feed.setInvalidationHandler(nil)
            ctx.coordinator.feed = feed
            ctx.coordinator.attach(view: view)
        }
        apply(to: ctx.coordinator)
        view.needsDisplay = true
    }

    public static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.feed.setInvalidationHandler(nil)
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

        init(feed: MonitorFeed, renderer: MonitorRenderer?) {
            self.feed = feed
            self.renderer = renderer
        }

        func attach(view: MTKView) {
            let box = WeakViewBox(view)
            feed.setInvalidationHandler {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { box.view?.needsDisplay = true }
                }
            }
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        public func draw(in view: MTKView) {
            let texture = feed.takeForDrawing()
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
