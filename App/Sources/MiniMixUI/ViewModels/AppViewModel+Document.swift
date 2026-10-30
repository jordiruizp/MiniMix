import Core
import Foundation

/// Estado de documento (T91): cambios sin guardar, proyecto nuevo y confirmaciones.
extension AppViewModel {
    /// Respuesta al aviso de cambios sin guardar.
    public enum UnsavedChoice: Sendable {
        case save, discard, cancel
    }

    /// Contenido que cuenta como «documento»: sin los buses (cambiar Preview/Programa durante la
    /// emisión no ensucia el proyecto).
    static func documentContent(_ project: Project) -> Project {
        var content = project
        content.preview = nil
        content.program = nil
        return content
    }

    /// Hay cambios desde el último guardado/apertura/proyecto nuevo.
    public var hasUnsavedChanges: Bool { isDirty }

    /// Marca el proyecto actual como guardado.
    func markSaved() { isDirty = false }

    /// Nombre del documento para el título de la ventana.
    public var documentName: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? "Sin título"
    }

    /// `true` si se puede seguir (sin cambios, se guardaron o se descartaron); `false` si se canceló
    /// o no se pudo guardar. `ask` muestra el aviso; `save` guarda (devuelve si lo consiguió).
    public func confirmDiscardChanges(ask: () -> UnsavedChoice, save: () -> Bool) -> Bool {
        guard hasUnsavedChanges else { return true }
        switch ask() {
        case .save: return save()
        case .discard: return true
        case .cancel: return false
        }
    }

    /// Proyecto vacío con el formato y la duración de fundido de las preferencias.
    public func newProject() async {
        let fresh = preferences.newProject
        projectURL = nil
        missingReferences = []
        await replaceProject(with: fresh, asSaved: true)
    }
}
