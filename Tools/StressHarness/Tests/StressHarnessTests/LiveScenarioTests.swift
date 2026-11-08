import Foundation
import Metal
import Testing
import TestSupport
@testable import StressHarnessKit

/// T90: escenarios cortos sobre los módulos reales (necesitan TestMedia y GPU).
@Suite("LiveScenario", .serialized,
       .enabled(if: TestMediaLocator.isGenerated && MTLCreateSystemDefaultDevice() != nil, "sin TestMedia o sin GPU"))
struct LiveScenarioTests {
    static let enforcePerformance = ProcessInfo.processInfo.environment["CI"] == nil

    @Test func cutsScenarioMeasuresLatencyAndWritesReport() async throws {
        var config = try #require(LiveScenarioConfig.named("stress-5m-cuts"))
        config.durationSeconds = 7
        config.sampleIntervalSeconds = 1
        config.warmupSeconds = 2
        let report = try await LiveScenarioRunner(config: config).run()
        #expect(report.inputs.count == 8)
        #expect(report.cuts.cuts + report.cuts.fades >= 2)
        #expect(report.program.analyzedFrames > 0)
        #expect(report.frames.rendered > 0 && report.frames.rendered <= report.frames.expected)
        #expect(report.targets.count == 8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minimix-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try report.write(to: dir)
        #expect(FileManager.default.fileExists(atPath: url.path))
        print("[perf] cuts: \(report.frames.dropped) perdidos, latencia máx. \(report.cuts.latencyFrames.max) fot., "
              + "negros \(report.program.black), arranque \(report.coldStart.firstProgramFrameSeconds ?? -1) s")
        guard Self.enforcePerformance else { return }
        #expect(report.cuts.measured >= 1 && report.cuts.latencyFrames.max <= 1)
        #expect(report.program.black == 0 && report.program.unreadable == 0)
        #expect((report.coldStart.firstProgramFrameSeconds ?? 99) < 2)
    }

    @Test func playlistScenarioStaysOnPlaylistClips() async throws {
        var config = try #require(LiveScenarioConfig.named("stress-5m-playlist"))
        config.durationSeconds = 8
        config.sampleIntervalSeconds = 1
        config.warmupSeconds = 2
        let report = try await LiveScenarioRunner(config: config).run()
        let playlist = try #require(report.playlist)
        #expect(playlist.items == 50)
        #expect(playlist.switches >= 1)
        #expect(playlist.maxLoadedItems <= 2)
        #expect(report.program.foreignClipFrames == 0)
        print("[perf] playlist: negros \(report.program.black), saltos \(report.program.skippedFrames)/"
              + "\(report.program.boundarySkips), lateSwitches \(playlist.lateSwitches)")
        guard Self.enforcePerformance else { return }
        #expect(report.program.black == 0)
    }
}
