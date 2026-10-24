// Persistence/SecurityScopedAccess.swift — ciclo start/stop del acceso security-scoped.

import Foundation
import os

/// Registro de los archivos cuyo acceso security-scoped está abierto.
///
/// Cada URL se abre como mucho una vez (`startAccessingSecurityScopedResource`) aunque se resuelva
/// muchas veces, y se cierra con `stopAccessing…` al soltarla, al abrir otro proyecto
/// (`retainOnly(_:)`) o al destruir el registro: el número de accesos del proceso nunca crece sin límite.
///
/// `@unchecked Sendable`: `open` solo se toca dentro de `lock`; las llamadas a start/stop se hacen fuera
/// del cerrojo y solo para URLs cuya propiedad acaba de cambiar dentro de él.
public final class SecurityScopedAccess: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var open: [String: URL] = [:]

    public init() {}

    deinit {
        for url in open.values { url.stopAccessingSecurityScopedResource() }
    }

    /// Número de archivos con acceso abierto ahora.
    public var activeCount: Int { locked { $0.count } }

    /// Rutas con acceso abierto (diagnóstico y tests).
    public var activePaths: Set<String> { locked { Set($0.keys) } }

    /// Abre el acceso a `url` si aún no estaba abierto. Devuelve `true` si queda abierto
    /// (fuera del sandbox el sistema puede no concederlo y devolver `false`; no es un error).
    @discardableResult
    public func begin(_ url: URL) -> Bool {
        let key = Self.key(url)
        if locked({ $0[key] != nil }) { return true }
        guard url.startAccessingSecurityScopedResource() else { return false }
        let duplicate = locked { open -> Bool in
            if open[key] != nil { return true }
            open[key] = url
            return false
        }
        // Otro hilo lo abrió a la vez: se cierra el acceso sobrante para mantener el equilibrio.
        if duplicate { url.stopAccessingSecurityScopedResource() }
        return true
    }

    /// Cierra el acceso a `url` si estaba abierto.
    public func end(_ url: URL) {
        let key = Self.key(url)
        let removed = locked { $0.removeValue(forKey: key) }
        removed?.stopAccessingSecurityScopedResource()
    }

    /// Cierra todos los accesos excepto los de `keep`.
    public func retainOnly(_ keep: Set<String>) {
        let keys = Set(keep.map { Self.key(URL(fileURLWithPath: $0)) })
        let closing = locked { open -> [URL] in
            let drop = open.filter { !keys.contains($0.key) }
            for key in drop.keys { open.removeValue(forKey: key) }
            return Array(drop.values)
        }
        for url in closing { url.stopAccessingSecurityScopedResource() }
    }

    /// Cierra todos los accesos.
    public func endAll() { retainOnly([]) }

    private func locked<R: Sendable>(_ body: (inout [String: URL]) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&open)
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
