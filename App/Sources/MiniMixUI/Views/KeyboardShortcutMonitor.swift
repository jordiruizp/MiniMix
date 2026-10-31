import AppKit
import SwiftUI

/// Condiciones para que una pulsación sea un atajo de la ventana principal (testeable sin AppKit).
public struct ShortcutContext: Hashable, Sendable {
    /// El evento va a la ventana que contiene `RootView` (no a un popover, panel u otra ventana).
    public var isMainWindow: Bool
    public var isKeyWindow: Bool
    /// Hoja adjunta (alertas de SwiftUI, paneles de guardar/abrir) o ventana modal activa.
    public var hasSheetOrModal: Bool
    public var isRepeat: Bool
    /// Hay un campo de texto editándose.
    public var isEditingText: Bool
    /// Navegación por teclado: un control con foco (botón, casilla…) y la tecla es Espacio/Intro,
    /// que deben activar ese control y no hacer Cut/Fundido.
    public var focusedControlUsesKey: Bool

    public init(isMainWindow: Bool, isKeyWindow: Bool, hasSheetOrModal: Bool, isRepeat: Bool, isEditingText: Bool,
                focusedControlUsesKey: Bool = false) {
        self.isMainWindow = isMainWindow
        self.isKeyWindow = isKeyWindow
        self.hasSheetOrModal = hasSheetOrModal
        self.isRepeat = isRepeat
        self.isEditingText = isEditingText
        self.focusedControlUsesKey = focusedControlUsesKey
    }

    public var allowsShortcuts: Bool {
        isMainWindow && isKeyWindow && !hasSheetOrModal && !isRepeat && !isEditingText && !focusedControlUsesKey
    }
}

/// Atajos de una tecla de la ventana principal (1–9, Espacio, Intro, ←/→, P).
/// Usa un monitor local de AppKit para no depender del foco de SwiftUI. Solo actúa en la ventana
/// principal cuando es la ventana clave, sin hojas/alertas/modales, sin autorrepetición y sin
/// edición de texto; las combinaciones con ⌘/⌃/⌥ las gestionan los menús.
struct KeyboardShortcutMonitor: ViewModifier {
    let app: AppViewModel
    @State private var monitor: Any?
    @State private var window = WindowReference()

    func body(content: Content) -> some View {
        content
            .background(WindowReader(reference: window))
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated { handle(event) } ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    @MainActor
    private func handle(_ event: NSEvent) -> Bool {
        guard let main = window.window else { return false }
        let key = Self.keyInput(from: event)
        let activationKey = key.special == .space || key.special == .enter
        let context = ShortcutContext(
            isMainWindow: event.window === main,
            isKeyWindow: main.isKeyWindow,
            hasSheetOrModal: main.attachedSheet != nil || NSApp.modalWindow != nil,
            isRepeat: event.isARepeat,
            isEditingText: main.firstResponder is NSText,
            focusedControlUsesKey: activationKey && Self.controlActivatesWithKey(
                main.firstResponder, fullKeyboardAccess: NSApp.isFullKeyboardAccessEnabled)
        )
        guard context.allowsShortcuts, let action = ShortcutMap.action(for: key) else { return false }
        app.perform(action)
        return true
    }

    /// Espacio/Intro deben activar el control con foco en vez de hacer Cut/Fundido solo si hay
    /// navegación por teclado completa y el control se activa con esas teclas (botones, menús
    /// emergentes, segmentados). Tablas (la lista de la playlist), deslizadores, etc. no: tras
    /// pulsar una fila, Espacio sigue siendo Cut.
    @MainActor
    static func controlActivatesWithKey(_ responder: NSResponder?, fullKeyboardAccess: Bool) -> Bool {
        guard fullKeyboardAccess, let responder else { return false }
        return responder is NSButton || responder is NSPopUpButton || responder is NSSegmentedControl
    }

    static func keyInput(from event: NSEvent) -> KeyInput {
        let special: KeyInput.Special? = switch event.keyCode {
        case 49: .space
        case 36, 76: .enter
        case 123: .left
        case 124: .right
        default: nil
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        return KeyInput(characters: event.charactersIgnoringModifiers ?? "", special: special,
                        hasCommandModifiers: !modifiers.isEmpty)
    }
}

/// Referencia débil a la ventana que aloja la vista.
@MainActor
final class WindowReference {
    weak var window: NSWindow?
}

/// Captura la `NSWindow` que contiene la jerarquía SwiftUI.
private struct WindowReader: NSViewRepresentable {
    let reference: WindowReference

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.reference = reference
        reference.window = view.window
    }

    final class ReaderView: NSView {
        var reference: WindowReference?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
}
