import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menús: ⌘S/⌘O (ProjectStoring), ⌘⇧F salida de Programa (OutputPresenting) y switcher.
public struct MiniMixCommands: Commands {
    let app: AppViewModel

    public init(app: AppViewModel) { self.app = app }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Abrir proyecto…") { openProject() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Guardar proyecto") { saveProject(askForURL: false) }
                .keyboardShortcut("s")
            Button("Guardar proyecto como…") { saveProject(askForURL: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Switcher") {
            Button("Cut (Espacio)") { app.perform(.cut) }
            Button("Fundido (Intro)") { app.perform(.fade) }
            Divider()
            Button("Mostrar/ocultar salida de Programa") { app.toggleProgramOutput() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }

    static let projectType = UTType(exportedAs: "com.ebrecode.minimix.project", conformingTo: .json)

    private func saveProject(askForURL: Bool) {
        if !askForURL, let url = app.projectURL {
            app.saveProject(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = "Proyecto.minimix"
        if panel.runModal() == .OK, let url = panel.url { app.saveProject(to: url) }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await app.openProject(from: url) }
    }
}
