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
}

extension ProjectStore {
    /// Reenlaza `reference` (todas las apariciones con su misma `path`) al archivo `newURL` y, a
    /// continuación, intenta resolver los demás archivos perdidos que estaban en la **misma carpeta
    /// original**: busca en la carpeta de `newURL` un archivo con el mismo nombre.
    public func relink(_ reference: MediaReference, to newURL: URL, in project: Project) throws -> Project {
        try relinkReporting(reference, to: newURL, in: project).project
    }

    /// Como `relink(_:to:in:)`, con el detalle de lo reenlazado (para el diálogo de la App).
    public func relinkReporting(_ reference: MediaReference, to newURL: URL,
                                in project: Project) throws -> RelinkResult {
        let target = newURL.standardizedFileURL
        guard BookmarkCodec.fileExists(target) else {
            throw PersistenceError.relinkTargetMissing(path: target.path)
        }
        let originalFolder = Self.folder(of: reference.path)
        let newFolder = target.deletingLastPathComponent()

        // Destino de cada ruta original: la elegida y las hermanas perdidas encontradas por nombre.
        var targets: [String: URL] = [reference.path: target]
        for lost in unresolvedReferences(in: project)
        where lost.path != reference.path && Self.folder(of: lost.path) == originalFolder {
            let candidate = newFolder.appendingPathComponent((lost.path as NSString).lastPathComponent)
            if BookmarkCodec.fileExists(candidate) { targets[lost.path] = candidate }
        }

        var bookmarks: [String: Data] = [:]
        for (path, url) in targets {
            bookmarks[path] = try? codec.makeBookmark(for: url).data
        }
        let relinked = project.mapMediaReferences { current in
            guard let url = targets[current.path] else { return current }
            return MediaReference(path: url.path, bookmark: bookmarks[current.path])
        }
        let ordered = project.mediaReferences.map(\.path).reduce(into: [String]()) { paths, path in
            if targets[path] != nil, !paths.contains(path) { paths.append(path) }
        }
        return RelinkResult(project: relinked, relinkedPaths: ordered,
                            stillUnresolved: unresolvedReferences(in: relinked))
    }

    static func folder(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
    }
}
