// Persistence/SchemaMigrations.swift — migraciones del esquema .minimix (N → N+1).
//
// Cada paso transforma el objeto JSON raíz de un documento en el esquema `from` al `from + 1`; el registro
// los encadena y fija `schemaVersion` tras cada paso. Se enchufa a `ProjectDecoder(migrate:)` de Core con
// `decoderHook`. Hoy solo existe el esquema 1, así que `standard` no tiene pasos: al publicar el esquema 2
// se añade aquí `SchemaMigration(from: 1) { … }` (y su test con un documento v1 real).

import Core
import Foundation

/// Un paso de migración del esquema `from` al `from + 1` sobre el objeto JSON raíz.
public struct SchemaMigration: Sendable {
    public typealias Transform = @Sendable (_ document: inout [String: Any]) throws -> Void

    public let from: Int
    public let transform: Transform

    public init(from: Int, transform: @escaping Transform) {
        self.from = from
        self.transform = transform
    }
}

public enum SchemaMigrationError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Falta el paso `from` → `from + 1`.
    case missingStep(from: Int)
    /// Dos pasos con el mismo origen.
    case duplicateStep(from: Int)
    /// El documento no es un objeto JSON.
    case notAnObject
    /// Se pidió migrar a una versión anterior o igual.
    case invalidRange(from: Int, to: Int)

    public var description: String {
        switch self {
        case .missingStep(let from): "Falta la migración del esquema \(from) al \(from + 1)"
        case .duplicateStep(let from): "Migración duplicada desde el esquema \(from)"
        case .notAnObject: "El documento no es un objeto JSON"
        case let .invalidRange(from, to): "No se puede migrar del esquema \(from) al \(to)"
        }
    }
}

/// Registro de migraciones encadenables.
public struct MigrationRegistry: Sendable {
    public let steps: [Int: SchemaMigration]

    public init(_ migrations: [SchemaMigration]) throws(SchemaMigrationError) {
        var steps: [Int: SchemaMigration] = [:]
        for migration in migrations {
            guard steps[migration.from] == nil else { throw .duplicateStep(from: migration.from) }
            steps[migration.from] = migration
        }
        self.steps = steps
    }

    private init(steps: [Int: SchemaMigration]) { self.steps = steps }

    /// Migraciones de MiniMix (esquema actual: `Project.currentSchemaVersion`). Hoy, ninguna.
    public static let standard = MigrationRegistry(steps: [:])

    /// Migra un documento JSON del esquema `version` al `target` aplicando cada paso en orden.
    public func migrate(_ data: Data, from version: Int,
                        to target: Int = Project.currentSchemaVersion) throws -> Data {
        guard version < target else { throw SchemaMigrationError.invalidRange(from: version, to: target) }
        // Comprueba la cadena completa antes de tocar el documento.
        for step in version..<target where steps[step] == nil {
            throw SchemaMigrationError.missingStep(from: step)
        }
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchemaMigrationError.notAnObject
        }
        for step in version..<target {
            try steps[step]?.transform(&document)
            document["schemaVersion"] = step + 1
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    /// Hook para `ProjectDecoder(migrate:)`: migra al esquema actual de Core.
    public var decoderHook: ProjectDecoder.Migration {
        let registry = self
        return { data, version in try registry.migrate(data, from: version) }
    }
}
