import AppKit
import SwiftUI

/// Salida de la app confirmada por el usuario (cerrar la ventana principal con cambios →
/// «No guardar»/«Guardar»): `applicationShouldTerminate` ya no vuelve a preguntar.
@MainActor
public enum QuitGuard {
    public static var confirmed = false

    /// Cerrar la ventana principal = salir de MiniMix (aunque Settings siga abierta): si hay
    /// cambios sin guardar se pregunta; si se cancela, la ventana no se cierra (antes la app
    /// quedaba sin ventana con el motor y la salida vivos).
    public static func shouldCloseMainWindow(confirm: () -> Bool, terminate: @escaping @MainActor () -> Void) -> Bool {
        guard confirm() else { return false }
        confirmed = true
        DispatchQueue.main.async { MainActor.assumeIsolated { terminate() } }
        return true
    }
}

/// Delegado intermedio de la ventana: intercepta `windowShouldClose` y reenvía todo lo demás al
/// delegado que puso SwiftUI.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var original: NSWindowDelegate?
    var shouldClose: () -> Bool = { true }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        return shouldClose()
    }

    /// Se coloca como delegado de `window` (una vez; si SwiftUI lo sustituye, se recoloca).
    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }
}

/// Instala `WindowCloseGuard` en la ventana que contiene la vista.
struct WindowCloseGuardView: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeCoordinator() -> WindowCloseGuard { WindowCloseGuard() }

    func makeNSView(context: Context) -> GuardHostView {
        let view = GuardHostView()
        view.closeGuard = context.coordinator
        context.coordinator.shouldClose = shouldClose
        return view
    }

    func updateNSView(_ view: GuardHostView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        if let window = view.window { context.coordinator.install(on: window) }
    }

    final class GuardHostView: NSView {
        var closeGuard: WindowCloseGuard?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { closeGuard?.install(on: window) }
        }
    }
}
