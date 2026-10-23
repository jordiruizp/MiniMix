import AppKit
import SwiftUI

/// Atajos de una tecla de la ventana principal (1–9, Espacio, Intro, ←/→, P).
/// Usa un monitor local de AppKit para no depender del foco de SwiftUI; no actúa mientras se
/// edita texto ni con ⌘/⌃/⌥ (esos los gestionan los menús).
struct KeyboardShortcutMonitor: ViewModifier {
    let app: AppViewModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
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
        if event.window?.firstResponder is NSText { return false }
        guard let action = ShortcutMap.action(for: Self.keyInput(from: event)) else { return false }
        app.perform(action)
        return true
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
