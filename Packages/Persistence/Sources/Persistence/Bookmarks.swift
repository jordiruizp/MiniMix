// Persistence/Bookmarks.swift — creación y resolución de bookmarks de archivos de medios.
//
// En la app empaquetada (sandbox) los bookmarks son security-scoped (`.withSecurityScope`, requiere el
// entitlement `com.apple.security.files.bookmarks.app-scope`) y hay que abrir el acceso con
// `startAccessingSecurityScopedResource()` antes de leer el archivo. Fuera del sandbox (tests, `swift run`)
// macOS también crea y resuelve bookmarks con `.withSecurityScope`, pero el acceso no es necesario y
// `startAccessingSecurityScopedResource()` puede devolver `false`: el código lo trata como «sin acceso que
// cerrar». Si la creación security-scoped falla, se recurre a un bookmark normal (sigue el archivo si se
// mueve en el mismo volumen, pero en sandbox no concede acceso tras reiniciar).

import Core
import Foundation

/// Tipo de bookmark que crea `ProjectStore`.
public enum BookmarkMode: Sendable, Hashable {
    /// `.withSecurityScope` (necesario en sandbox); si falla, cae a un bookmark normal.
    case securityScoped
    /// Bookmark normal (sin ámbito de seguridad). Útil en herramientas fuera del sandbox.
    case plain
}

/// Resultado de resolver una referencia a un archivo.
struct ResolvedMedia: Sendable {
    let url: URL
    /// `true` si el URL salió de un bookmark security-scoped (hay que abrir/cerrar el acceso).
    let isSecurityScoped: Bool
    /// El bookmark está caducado (o no había) y conviene regenerarlo.
    let needsNewBookmark: Bool
}

/// Operaciones de bookmark sin estado.
struct BookmarkCodec: Sendable {
    let mode: BookmarkMode

    /// Bookmark para `url` (que debe existir). Devuelve también si es security-scoped.
    func makeBookmark(for url: URL) throws -> (data: Data, securityScoped: Bool) {
        if mode == .securityScoped,
           let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            return (data, true)
        }
        return (try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), false)
    }

    /// Resuelve `data` sin interacción con el usuario ni montaje de volúmenes. Prueba primero como
    /// security-scoped y después como bookmark normal (un proyecto puede mezclar los dos).
    func resolveBookmark(_ data: Data) -> ResolvedMedia? {
        let quiet: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: quiet.union(.withSecurityScope),
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return ResolvedMedia(url: url, isSecurityScoped: true, needsNewBookmark: stale)
        }
        stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: quiet, relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return ResolvedMedia(url: url, isSecurityScoped: false, needsNewBookmark: stale)
        }
        return nil
    }

    /// Localiza el archivo de `reference`: primero por bookmark, después por `path`.
    /// nil si el archivo no existe en ninguno de los dos sitios.
    func resolve(_ reference: MediaReference) -> ResolvedMedia? {
        if let bookmark = reference.bookmark, let resolved = resolveBookmark(bookmark),
           Self.fileExists(resolved.url) {
            return resolved
        }
        let url = URL(fileURLWithPath: reference.path)
        guard !reference.path.isEmpty, Self.fileExists(url) else { return nil }
        return ResolvedMedia(url: url, isSecurityScoped: false, needsNewBookmark: true)
    }

    static func fileExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Mismo archivo aunque la ruta difiera por enlaces simbólicos (p. ej. `/var` y `/private/var`).
    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }
}
