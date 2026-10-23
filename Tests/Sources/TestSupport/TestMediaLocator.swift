import Foundation

/// Localiza TestMedia/ (generado por Tools/, no versionado).
public enum TestMediaLocator {
    public static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestMedia")
    }
}
