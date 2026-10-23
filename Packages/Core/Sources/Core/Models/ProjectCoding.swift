// Core/Models/ProjectCoding.swift — codificación estable y decodificación versionada de .minimix (T10).
//
// - `ProjectEncoder`: JSON con claves ordenadas y sangría fija → archivos diffables y deterministas.
// - `ProjectDecoder`: lee primero `schemaVersion`; rechaza versiones futuras con un error claro y,
//   para versiones antiguas, delega en el hook `migrate` (las migraciones reales son de Persistence · T82).

import Foundation

/// Errores de lectura de un documento .minimix.
public enum ProjectCodingError: Error, Hashable, Sendable, CustomStringConvertible {
    /// El JSON no tiene `schemaVersion` (o no es un objeto JSON).
    case missingSchemaVersion
    /// `schemaVersion` < 1.
    case invalidSchemaVersion(Int)
    /// Documento creado por una versión más nueva de MiniMix.
    case unsupportedFutureVersion(found: Int, supported: Int)
    /// Versión antigua sin migración disponible.
    case migrationUnavailable(from: Int, to: Int)
    /// La migración no produjo un documento en la versión actual.
    case migrationFailed(from: Int, reason: String)
    /// JSON mal formado o con forma incorrecta.
    case corrupted(String)

    public var description: String {
        switch self {
        case .missingSchemaVersion:
            "El documento no indica schemaVersion"
        case .invalidSchemaVersion(let version):
            "schemaVersion inválida: \(version)"
        case let .unsupportedFutureVersion(found, supported):
            "El proyecto usa el esquema \(found), más nuevo que el soportado (\(supported)). Actualiza MiniMix."
        case let .migrationUnavailable(from, to):
            "No hay migración del esquema \(from) al \(to)"
        case let .migrationFailed(from, reason):
            "Falló la migración desde el esquema \(from): \(reason)"
        case .corrupted(let reason):
            "Proyecto dañado: \(reason)"
        }
    }
}

/// Codificador estable de proyectos (claves ordenadas, sangría, sin escapar `/`).
public struct ProjectEncoder: Sendable {
    public init() {}

    public func encode(_ project: Project) throws -> Data {
        try Self.makeJSONEncoder().encode(project)
    }

    /// `JSONEncoder` configurado para salida estable; útil para codificar otros modelos igual.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        encoder.nonConformingFloatEncodingStrategy = .throw
        return encoder
    }
}

/// Decodificador versionado de proyectos.
public struct ProjectDecoder: Sendable {
    /// Migra los bytes JSON de un documento en `fromVersion` (< actual) a la versión actual.
    public typealias Migration = @Sendable (_ data: Data, _ fromVersion: Int) throws -> Data

    /// Versión más alta que este decodificador acepta.
    public var supportedVersion: Int
    /// Hook de migración (lo aporta Persistence). nil → las versiones antiguas fallan.
    public var migrate: Migration?

    public init(supportedVersion: Int = Project.currentSchemaVersion, migrate: Migration? = nil) {
        self.supportedVersion = supportedVersion
        self.migrate = migrate
    }

    /// Lee solo la versión de esquema del documento.
    public static func schemaVersion(of data: Data) throws(ProjectCodingError) -> Int {
        struct Header: Decodable { let schemaVersion: Int? }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch DecodingError.dataCorrupted(let context) {
            throw .corrupted(context.debugDescription)
        } catch {
            // Raíz que no es un objeto o `schemaVersion` que no es entero.
            throw .missingSchemaVersion
        }
        guard let version = header.schemaVersion else { throw .missingSchemaVersion }
        return version
    }

    public func decode(_ data: Data) throws(ProjectCodingError) -> Project {
        let version = try Self.schemaVersion(of: data)
        guard version >= 1 else { throw .invalidSchemaVersion(version) }
        if version > supportedVersion {
            throw .unsupportedFutureVersion(found: version, supported: supportedVersion)
        }
        var current = data
        if version < supportedVersion {
            guard let migrate else { throw .migrationUnavailable(from: version, to: supportedVersion) }
            do {
                current = try migrate(data, version)
            } catch {
                throw .migrationFailed(from: version, reason: String(describing: error))
            }
            let migrated = try Self.schemaVersion(of: current)
            guard migrated == supportedVersion else {
                throw .migrationFailed(from: version, reason: "resultado en esquema \(migrated)")
            }
        }
        do {
            return try JSONDecoder().decode(Project.self, from: current)
        } catch {
            throw .corrupted(String(describing: error))
        }
    }
}
