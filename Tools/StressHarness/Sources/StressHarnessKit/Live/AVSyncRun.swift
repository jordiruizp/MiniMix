import Foundation
import TestSupport

/// Escenario `av-sync` (T90): mide el desfase A/V con la claqueta y escribe un JSON en `Tools/reports/`.
public enum AVSyncRun {
    public struct Report: Codable, Sendable {
        public var schemaVersion = 1
        public var startedAt: Date
        public var machine: MachineInfo
        public var ciRunnerActiveAtStart: Bool
        public var targetMs = 20.0
        public var pass: Bool
        public var result: AVSyncResult
    }

    /// Devuelve el resumen y la ruta del informe.
    public static func run(seconds: Double, to directory: URL) async throws -> (summary: String, url: URL) {
        let startedAt = Date()
        let ci = CIRunner.isActive()
        let result = try await AVSyncProbe.measure(seconds: seconds)
        let report = Report(startedAt: startedAt, machine: MachineInfo.current(), ciRunnerActiveAtStart: ci,
                            pass: !result.pairs.isEmpty && result.maxAbsMs < 20, result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = directory.appendingPathComponent("av-sync-real-\(formatter.string(from: startedAt)).json")
        try encoder.encode(report).write(to: url, options: .withoutOverwriting)
        let mark = report.pass ? "✔" : "✘"
        return ("\(mark) \(result.summary)" + (ci ? " — ⚠ CI activo" : ""), url)
    }
}
