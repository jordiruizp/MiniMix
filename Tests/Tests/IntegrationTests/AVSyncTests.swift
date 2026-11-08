import Foundation
import Metal
import Testing
@testable import TestSupport

/// T90 · sincronismo A/V (plan 10.2: |desfase| < 20 ms) con la claqueta de TestMedia y la cadena real
/// de la App (`VideoInput` con tap alineado, `AudioEngine` con perfil `.playerTap`). Mide y escribe
/// siempre; exige el objetivo solo fuera de CI. Se omite sin GPU, sin TestMedia o sin salida de audio.
@Suite("AVSync", .serialized,
       .enabled(if: TestMediaLocator.isGenerated && MTLCreateSystemDefaultDevice() != nil, "sin TestMedia o sin GPU"))
struct AVSyncTests {
    static let enforcePerformance = ProcessInfo.processInfo.environment["CI"] == nil

    @Test func clapperOffsetIsUnder20Milliseconds() async throws {
        let result: AVSyncResult
        do {
            result = try await AVSyncProbe.measure(seconds: 12)
        } catch AVSyncProbeError.noAudio(let detail) {
            print("[perf] A/V omitido: \(detail)")
            return
        }
        print("[perf] \(result.summary)")
        print("[perf] desfases (ms): " + result.pairs.map { String(format: "%+.1f", $0.offsetMs) }.joined(separator: " "))
        #expect(result.syncProfile == "playerTap")
        #expect(!result.pairs.isEmpty, "sin pares claqueta/pitido")
        guard Self.enforcePerformance else { return }
        #expect(result.pairs.count >= 8, "pares: \(result.pairs.count)")
        #expect(abs(result.meanMs) < 20, "media \(result.meanMs) ms")
        #expect(result.maxAbsMs < 20, "|máx| \(result.maxAbsMs) ms")
    }
}
