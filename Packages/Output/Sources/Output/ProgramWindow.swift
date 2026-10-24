// Output/ProgramWindow.swift — ventana de Programa a pantalla completa sin bordes.

import AppKit
import Core
import Render
import SwiftUI

/// Superficie donde se muestra el Programa. La real es `ProgramWindowSurface`; los tests usan una falsa.
@MainActor
public protocol ProgramSurface: AnyObject {
    /// Muestra (o recoloca, si ya está visible) la salida cubriendo `display`. Idempotente.
    func present(on display: DisplayDescriptor)
    /// Oculta la salida sin destruirla (se puede volver a mostrar).
    func dismiss()
    var isVisible: Bool { get }
}

/// Ventana sin bordes que no puede ser key ni main: no roba el foco ni el menú a la ventana principal.
final class ProgramWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Vista contenedora que oculta el cursor mientras está sobre la salida, aunque la ventana no sea key:
/// la tracking area `.activeAlways` entrega `cursorUpdate` también a ventanas no key (los cursor rects
/// solo actúan en la key window, por eso no bastan). Requiere `ignoresMouseEvents == false`.
final class CursorHidingView: NSView {
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.blankCursor.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.blankCursor)
    }
}

/// Ventana de Programa real: `NSWindow` borderless sobre la pantalla elegida con un `MonitorView`
/// de Render (sin borde) alimentado por un `MonitorFeed`.
///
/// - Nivel por encima de la barra de menús (`mainMenu + 1`) para cubrir también la barra de esa pantalla.
/// - `collectionBehavior`: en todos los Spaces, estacionaria (Mission Control no la mueve ni la agrupa),
///   fuera del ciclo de ventanas (⌘`) y sin pantalla completa nativa.
/// - Se ordena con `orderFrontRegardless()`: nunca se hace key ni activa la app.
/// - En pantalla externa recibe el ratón (`ignoresMouseEvents == false`) para ocultar el cursor; como no
///   puede ser key ni main, un clic no roba el foco a la ventana principal. En la pantalla integrada
///   ignora el ratón (el cursor se ve y los clics pasan a la interfaz de debajo).
@MainActor
public final class ProgramWindowSurface: ProgramSurface {
    public let feed: MonitorFeed
    public let renderer: MonitorRenderer?
    private(set) var window: ProgramWindow?

    public init(feed: MonitorFeed, renderer: MonitorRenderer?) {
        self.feed = feed
        self.renderer = renderer
    }

    /// Con el renderer compartido de `context` (`nil` → salida negra).
    public convenience init(feed: MonitorFeed, context: MetalContext?) {
        self.init(feed: feed, renderer: context.flatMap(MonitorRenderer.shared(for:)))
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    public func present(on display: DisplayDescriptor) {
        let window = prepareWindow(for: display)
        if window.frame != display.frame {
            window.setFrame(display.frame, display: true)
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    public func dismiss() {
        window?.orderOut(nil)
    }

    /// Crea (una vez) y configura la ventana para `display` sin mostrarla.
    func prepareWindow(for display: DisplayDescriptor) -> ProgramWindow {
        let window = window ?? makeWindow()
        self.window = window
        window.ignoresMouseEvents = display.info.isBuiltIn
        return window
    }

    private func makeWindow() -> ProgramWindow {
        let window = ProgramWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.title = "MiniMix Program"

        let container = CursorHidingView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let monitor = NSHostingView(rootView: MonitorView(feed: feed, renderer: renderer, borderColor: nil, borderWidth: 0))
        monitor.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(monitor)
        NSLayoutConstraint.activate([
            monitor.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            monitor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            monitor.topAnchor.constraint(equalTo: container.topAnchor),
            monitor.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
        return window
    }
}
