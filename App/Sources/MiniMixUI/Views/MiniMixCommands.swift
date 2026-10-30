import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menús (T91): Archivo (⌘N, ⌘O, ⌘S, ⌘⇧S con aviso de cambios sin guardar) y Switcher con todos
/// los comandos y sus teclas visibles; ⌘⇧F salida de Programa.
public struct MiniMixCommands: Commands {
    let app: AppViewModel

    public init(app: AppViewModel) { self.app = app }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Proyecto nuevo") { ProjectDialogs.newProject(app) }
                .keyboardShortcut("n")
            Button("Abrir proyecto…") { ProjectDialogs.open(app) }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Guardar proyecto") { ProjectDialogs.save(app, askForURL: false) }
                .keyboardShortcut("s")
            Button("Guardar proyecto como…") { ProjectDialogs.save(app, askForURL: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Proyecto") {
            Button("Formato del proyecto…") { app.isEditingProjectFormat = true }
        }
        CommandMenu("Switcher") {
            let items = app.switcherMenuItems
            ForEach(items.filter(\.selectsInput)) { item in
                Button(item.menuTitle) { app.perform(item.action) }.disabled(!item.isEnabled)
            }
            Divider()
            ForEach(items.filter { !$0.selectsInput }) { item in
                Button(item.menuTitle) { app.perform(item.action) }.disabled(!item.isEnabled)
            }
            Divider()
            Button(app.programOutputDisplay == nil ? "Mostrar salida de Programa" : "Ocultar salida de Programa") {
                app.toggleProgramOutput()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

/// Diálogos de documento (AppKit): aviso de cambios sin guardar, guardar/abrir y proyecto nuevo.
@MainActor
public enum ProjectDialogs {
    static let projectType = UTType(exportedAs: "com.ebrecode.minimix.project", conformingTo: .json)

    /// Aviso estándar «¿Guardar los cambios?».
    public static func askUnsaved(_ app: AppViewModel) -> AppViewModel.UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = "¿Guardar los cambios de «\(app.documentName)»?"
        alert.informativeText = "Si no los guardas, se perderán."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "No guardar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// `true` si se puede descartar el proyecto actual (sin cambios, guardado o descartado).
    public static func confirmDiscard(_ app: AppViewModel) -> Bool {
        app.confirmDiscardChanges(ask: { askUnsaved(app) }, save: { save(app, askForURL: false) })
    }

    /// Guarda (pidiendo destino si hace falta). Devuelve si se guardó.
    @discardableResult
    public static func save(_ app: AppViewModel, askForURL: Bool) -> Bool {
        if !askForURL, let url = app.projectURL { return app.saveProject(to: url) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [projectType]
        panel.nameFieldStringValue = "\(app.documentName).minimix"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return app.saveProject(to: url)
    }

    public static func open(_ app: AppViewModel) {
        guard confirmDiscard(app) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await app.openProject(from: url) }
    }

    /// Confirmación para cambiar el formato con la salida de Programa en el aire.
    public static func confirmFormatChangeWhileLive() -> Bool {
        let alert = NSAlert()
        alert.messageText = "¿Cambiar el formato durante la emisión?"
        alert.informativeText = "La salida de Programa está activa. El render se reconfigurará y puede verse un salto."
        alert.addButton(withTitle: "Cambiar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public static func newProject(_ app: AppViewModel) {
        guard confirmDiscard(app) else { return }
        Task { await app.newProject() }
    }
}
