// Persistence/ProjectStore.swift — guardar/abrir .minimix (T82).

import Core
import Foundation

/// Errores de Persistence (además de `ProjectCodingError` de Core al decodificar).
public enum PersistenceError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No se encuentra el archivo de la referencia (ni por bookmark ni por ruta).
    case unresolvedReference(path: String)
    /// El destino de un reenlace no existe o no es un archivo.
    case relinkTargetMissing(path: String)

    public var description: String {
        switch self {
        case .unresolvedReference(let path): "No se encuentra el archivo: \(path)"
        case .relinkTargetMissing(let path): "El archivo elegido no existe: \(path)"
        }
    }
}

/// Persistencia de proyectos `.minimix`.
///
/// - **Guardar**: crea un bookmark para cada `MediaReference` que no lo tenga o lo tenga caducado
///   (si el archivo existe), codifica con `ProjectEncoder` (JSON estable) y escribe de forma atómica.
/// - **Abrir**: decodifica con `ProjectDecoder` + `MigrationRegistry`, resuelve los bookmarks, abre el
///   acceso security-scoped de cada archivo, regenera los bookmarks caducados y actualiza `path` si el
///   archivo se movió. `load` **no** cierra accesos: el proyecto actual sigue leyéndose (bucles, seeks
///   recrean lectores) y la App puede descartar lo abierto (cancelar, importar).
/// - **Activar**: cuando la App ya ha cambiado sus entradas al proyecto nuevo, llama a `activate(_:)`
///   para cerrar los accesos que ese proyecto no usa.
/// - **Reenlace**: `unresolvedReferences(in:)` y `relink(_:to:in:)`.
/// - **Media**: `urlResolver` para `InputManager(urlResolver:)`.
///
/// Las copias de un `ProjectStore` comparten el registro de accesos (`access`).
public struct ProjectStore: ProjectStoring {
    /// Extensión de los documentos de proyecto.
    public static let fileExtension = "minimix"

    public let bookmarkMode: BookmarkMode
    public let migrations: MigrationRegistry
    /// Accesos security-scoped abiertos por este store (y sus copias).
    public let access: SecurityScopedAccess

    var codec: BookmarkCodec { BookmarkCodec(mode: bookmarkMode) }

    public init(bookmarkMode: BookmarkMode = .securityScoped,
                migrations: MigrationRegistry = .standard,
                access: SecurityScopedAccess = SecurityScopedAccess()) {
        self.bookmarkMode = bookmarkMode
        self.migrations = migrations
        self.access = access
    }

    // MARK: Guardar

    public func save(_ project: Project, to url: URL) throws {
        try write(project, to: url)
    }

    /// Guarda y devuelve el proyecto tal como queda en disco (con los bookmarks creados o renovados):
    /// la App debe adoptarlo como su proyecto actual para no regenerarlos en cada guardado.
    @discardableResult
    public func write(_ project: Project, to url: URL) throws -> Project {
        let stored = withFreshBookmarks(project)
        let data = try ProjectEncoder().encode(stored)
        try data.write(to: url, options: .atomic)
        return stored
    }

    /// Copia del proyecto con bookmark en cada referencia cuyo archivo existe y no lo tenía (o caducó).
    public func withFreshBookmarks(_ project: Project) -> Project {
        project.mapMediaReferences(refreshed)
    }

    // MARK: Abrir

    public func load(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url)
        let decoded = try ProjectDecoder(migrate: migrations.decoderHook).decode(data)
        return decoded.mapMediaReferences { reference -> MediaReference in
            guard let resolved = codec.resolve(reference) else { return reference }
            if resolved.isSecurityScoped { access.begin(resolved.url) }
            return refreshed(reference, resolved: resolved)
        }
    }

    /// `project` pasa a ser el proyecto en uso: abre el acceso a sus archivos y cierra el de todos los
    /// demás. La App lo llama **después** de haber sustituido las entradas de Media (nunca antes: los
    /// lectores del proyecto anterior perderían el acceso).
    public func activate(_ project: Project) {
        var keep = Set<String>()
        for reference in project.mediaReferences {
            guard let resolved = codec.resolve(reference), resolved.isSecurityScoped else { continue }
            if access.begin(resolved.url) { keep.insert(resolved.url.path) }
        }
        access.retainOnly(keep)
    }

    // MARK: Resolución

    public func unresolvedReferences(in project: Project) -> [MediaReference] {
        var seen = Set<String>()
        return project.mediaReferences.filter { reference in
            codec.resolve(reference) == nil && seen.insert(reference.path).inserted
        }
    }

    /// URL del archivo de `reference` (bookmark → ruta), con el acceso security-scoped abierto.
    public func resolveURL(for reference: MediaReference) throws -> URL {
        guard let resolved = codec.resolve(reference) else {
            throw PersistenceError.unresolvedReference(path: reference.path)
        }
        if resolved.isSecurityScoped { access.begin(resolved.url) }
        return resolved.url
    }

    /// Resolutor para `InputManager(urlResolver:)` de Media.
    public var urlResolver: @Sendable (MediaReference) throws -> URL {
        let store = self
        return { try store.resolveURL(for: $0) }
    }

    /// Cierra todos los accesos security-scoped abiertos (al cerrar el proyecto o salir).
    public func stopAccessingAll() {
        access.endAll()
    }

    // MARK: Internos

    /// Referencia con bookmark vigente y `path` al día; sin cambios si el archivo no aparece.
    func refreshed(_ reference: MediaReference) -> MediaReference {
        guard let resolved = codec.resolve(reference) else { return reference }
        // En sandbox, regenerar un bookmark security-scoped exige tener el acceso abierto.
        if resolved.isSecurityScoped, resolved.needsNewBookmark { access.begin(resolved.url) }
        return refreshed(reference, resolved: resolved)
    }

    func refreshed(_ reference: MediaReference, resolved: ResolvedMedia) -> MediaReference {
        var updated = reference
        if !BookmarkCodec.samePath(reference.path, resolved.url.path) {
            updated.path = resolved.url.path
        }
        if resolved.needsNewBookmark || reference.bookmark == nil,
           let bookmark = try? codec.makeBookmark(for: resolved.url) {
            updated.bookmark = bookmark.data
        }
        return updated
    }
}
