import Foundation

/// Localiza TestMedia/ (generado por `Tools/generate-testmedia.sh`, no versionado).
public enum TestMediaLocator {
    public static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestMedia")
    }

    public static var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    public static func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    /// true si los medios están generados (la suma de comprobación la escribe el generador al final).
    public static var isGenerated: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("checksums.sha256").path)
    }

    public static func manifest() throws -> TestMediaManifest {
        try JSONDecoder().decode(TestMediaManifest.self, from: Data(contentsOf: manifestURL))
    }
}

/// `TestMedia/manifest.json` (versionado).
public struct TestMediaManifest: Decodable, Sendable {
    public struct Audio: Decodable, Sendable, Equatable {
        public var codec: String
        public var sampleRate: Int
        public var channels: Int
    }

    public struct CodeRange: Decodable, Sendable, Equatable {
        public var clipID: Int
        public var first: Int
        public var last: Int
    }

    public struct File: Decodable, Sendable {
        public var file: String
        public var kind: String
        public var codec: String
        public var width: Int?
        public var height: Int?
        public var frameRate: String?
        public var fps: Double?
        public var frames: Int?
        public var duration: Double?
        public var alpha: Bool
        public var audio: Audio?
        public var frameCode: CodeRange?
        public var clapper: Bool
        public var purpose: String

        public var url: URL { TestMediaLocator.url(file) }
    }

    public struct SetItem: Decodable, Sendable {
        public struct Color: Decodable, Sendable, Equatable {
            public var red, green, blue, alpha: Double
        }
        public var type: String
        public var file: String?
        public var color: Color?
        public var duration: Double?
    }

    public struct MediaSet: Decodable, Sendable {
        public var name: String
        public var purpose: String
        public var items: [SetItem]
    }

    public var schemaVersion: Int
    public var generatorVersion: Int
    public var files: [File]
    public var sets: [MediaSet]

    public func file(_ path: String) -> File? { files.first { $0.file == path } }
    public func set(_ name: String) -> MediaSet? { sets.first { $0.name == name } }
}
