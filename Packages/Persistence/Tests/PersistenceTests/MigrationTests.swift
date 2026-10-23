import Core
import Foundation
import Testing
@testable import Persistence

@Suite("Migraciones de esquema")
struct MigrationTests {
    /// Esquema 0 sintético: `format` en lugar de `canvas`, `sources` en lugar de `inputs` y sin `masterVolume`.
    private static let v0Document = """
    {
      "schemaVersion": 0,
      "format": {"size": {"width": 1280, "height": 720}, "frameRate": {"numerator": 25, "denominator": 1}},
      "sources": [],
      "defaultFadeDuration": 2
    }
    """

    private static let v0ToV1 = SchemaMigration(from: 0) { document in
        document["canvas"] = document.removeValue(forKey: "format")
        document["inputs"] = document.removeValue(forKey: "sources") ?? []
        if document["masterVolume"] == nil { document["masterVolume"] = 1 }
    }

    @Test func syntheticV0MigratesToCurrentSchema() throws {
        let registry = try MigrationRegistry([Self.v0ToV1])
        let migrated = try registry.migrate(Data(Self.v0Document.utf8), from: 0)
        #expect(try ProjectDecoder.schemaVersion(of: migrated) == Project.currentSchemaVersion)

        let project = try ProjectDecoder().decode(migrated)
        #expect(project == Project(canvas: CanvasFormat(size: .hd720, frameRate: .fps25), defaultFadeDuration: 2))
    }

    @Test func decoderHookMigratesLikeTheRegistry() throws {
        let registry = try MigrationRegistry([Self.v0ToV1])
        let viaHook = try registry.decoderHook(Data(Self.v0Document.utf8), 0)
        let direct = try registry.migrate(Data(Self.v0Document.utf8), from: 0)
        #expect(try ProjectDecoder().decode(viaHook) == ProjectDecoder().decode(direct))
    }

    @Test func stepsAreChainedInOrder() throws {
        let registry = try MigrationRegistry([
            SchemaMigration(from: 1) { $0["trail"] = (($0["trail"] as? String) ?? "") + "b" },
            SchemaMigration(from: 0) { $0["trail"] = "a" }
        ])
        let data = try registry.migrate(Data(#"{"schemaVersion":0}"#.utf8), from: 0, to: 2)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["trail"] as? String == "ab")
        #expect(object["schemaVersion"] as? Int == 2)
    }

    @Test func missingStepFailsBeforeTouchingTheDocument() throws {
        let registry = try MigrationRegistry([Self.v0ToV1])
        #expect(throws: SchemaMigrationError.missingStep(from: 1)) {
            try registry.migrate(Data(Self.v0Document.utf8), from: 0, to: 2)
        }
        #expect(throws: SchemaMigrationError.missingStep(from: 0)) {
            try MigrationRegistry.standard.migrate(Data(Self.v0Document.utf8), from: 0)
        }
    }

    @Test func duplicateStepsAreRejected() {
        #expect(throws: SchemaMigrationError.duplicateStep(from: 0)) {
            try MigrationRegistry([Self.v0ToV1, Self.v0ToV1])
        }
    }

    @Test func invalidRangeAndNonObjectAreRejected() throws {
        let registry = try MigrationRegistry([Self.v0ToV1])
        #expect(throws: SchemaMigrationError.invalidRange(from: 1, to: 1)) {
            try registry.migrate(Data("{}".utf8), from: 1)
        }
        #expect(throws: SchemaMigrationError.notAnObject) {
            try registry.migrate(Data("[1]".utf8), from: 0)
        }
    }
}
