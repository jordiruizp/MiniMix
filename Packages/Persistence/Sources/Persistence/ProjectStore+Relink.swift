// Persistence/ProjectStore+Relink.swift — reenlace de archivos perdidos (T82).

import Core
import Foundation

/// Resultado de un reenlace.
public struct RelinkResult: Hashable, Sendable {
    /// Proyecto con las referencias reenlazadas (y sus bookmarks nuevos).
    public var project: Project
    /// Rutas originales reenlazadas: la elegida y las encontradas automáticamente.
    public var relinkedPaths: [String]
    /// Referencias que siguen sin resolver.
    public var stillUnresolved: [MediaReference]
    /// Rutas originales reenlazadas cuyo bookmark no se pudo crear (quedan solo con `path`;
    /// en sandbox no se podrán abrir tras reiniciar).
    public var bookmarkFailures: [String]
}

extension ProjectStore {
    /// Reenlaza `reference` (todas las apariciones con su misma `path`) al archivo `newURL` y, a
    /// continuación, intenta resolver los demás archivos perdidos que estaban en la **misma carpeta
    /// original**: busca un archivo con el mismo nombre en `folder` (o, si es nil, en la carpeta de `newURL`).
    ///
    /// **Sandbox:** elegir un solo archivo en `NSOpenPanel` solo da acceso a ese archivo, no a sus
    /// hermanos. Para el reenlace automático, la App debe pedir la **carpeta** (panel con
    /// `canChooseDirectories`) y pasarla como `folder`: aquí se abre su acceso security-scoped mientras
    /// dura la búsqueda y la creación de bookmarks.
    public func relink(_ reference: MediaReference, to newURL: URL, in project: Project,
                       searchingIn folder: URL? = nil) throws -> Project {
        try relinkReporting(reference, to: newURL, in: project, searchingIn: folder).project
    }

    /// Como `relink(_:to:in:searchingIn:)`, con el detalle de lo reenlazado (para el diálogo de la App).
    public func relinkReporting(_ reference: MediaReference, to newURL: URL, in project: Project,
                                searchingIn folder: URL? = nil) throws -> RelinkResult {
        let target = newURL.standardizedFileURL
        guard BookmarkCodec.fileExists(target) else {
            throw PersistenceError.relinkTargetMissing(path: target.path)
        }
        let searchFolder = (folder ?? target.deletingLastPathComponent()).standardizedFileURL
        let folderAccess = folder?.startAccessingSecurityScopedResource() ?? false
        defer { if folderAccess { folder?.stopAccessingSecurityScopedResource() } }

        let originalFolder = Self.folder(of: reference.path)
        // Destino de cada ruta original: la elegida y las hermanas perdidas encontradas por nombre.
        var targets: [String: URL] = [reference.path: target]
        for lost in unresolvedReferences(in: project)
        where lost.path != reference.path && Self.folder(of: lost.path) == originalFolder {
            let candidate = searchFolder.appendingPathComponent((lost.path as NSString).lastPathComponent)
            if BookmarkCodec.fileExists(candidate) { targets[lost.path] = candidate }
        }

        var bookmarks: [String: Data] = [:]
        var failures: [String] = []
        for (path, url) in targets {
            do {
                bookmarks[path] = try codec.makeBookmark(for: url).data
            } catch {
                let reason = String(describing: error)
                persistenceLog.error("Relink: cannot create bookmark: \(reason, privacy: .public)")
                failures.append(path)
            }
        }
        let relinked = project.mapMediaReferences { current in
            guard let url = targets[current.path] else { return current }
            return MediaReference(path: url.path, bookmark: bookmarks[current.path])
        }
        let ordered = project.mediaReferences.map(\.path).reduce(into: [String]()) { paths, path in
            if targets[path] != nil, !paths.contains(path) { paths.append(path) }
        }
        return RelinkResult(project: relinked, relinkedPaths: ordered,
                            stillUnresolved: unresolvedReferences(in: relinked),
                            bookmarkFailures: ordered.filter(failures.contains))
    }

    static func folder(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
    }
}
