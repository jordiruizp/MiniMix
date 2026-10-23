import Core
import Foundation
import Testing
@testable import StressHarnessKit

@Suite("ScenarioRunner", .serialized)
struct ScenarioRunnerTests {
    private static let canvas = CanvasFormat(size: PixelSize(width: 640, height: 360), frameRate: .fps30)

    @Test(arguments: PipelineRegistry.factories.keys.sorted())
    func switchScenarioProducesReport(pipeline: String) async throws {
        let config = ScenarioConfig(name: "test-switch", kind: .switchEvery(seconds: 0.3, transition: .cut, fadeSeconds: 0),
                                    durationSeconds: 1.5, canvas: Self.canvas, inputs: 3, sampleIntervalSeconds: 0.25)
        let factory = try #require(PipelineRegistry.make(pipeline))
        let report = try await ScenarioRunner(config: config, factory: factory).run()
        #expect(report.pipeline == pipeline)
        #expect(report.frames.expected == 45)
        #expect(report.frames.rendered > 15, "rendered \(report.frames.rendered)")
        #expect(report.frames.rendered <= report.frames.expected)
        #expect(report.events.switches >= 3)
        #expect(report.durationSeconds >= 1.4)
        #expect(!report.samples.isEmpty)
        #expect(report.memory.peakMB > 1)
        #expect(report.machine.memoryGB > 1)
        // Llegada real de los ticks (30 fps → ~33 ms), distinta de las marcas ideales.
        #expect((20...60).contains(report.deliveryIntervalMs.p50), "\(report.deliveryIntervalMs)")
        #expect(report.deliveryIntervalMs.max >= report.deliveryIntervalMs.p50)
        #expect(report.deliveryIntervalMs.mean != report.tickIntervalMs.mean)
    }

    @Test func fadeScenarioCompletesTransitions() async throws {
        let config = ScenarioConfig(name: "test-fade", kind: .switchEvery(seconds: 0.5, transition: .fade, fadeSeconds: 0.2),
                                    durationSeconds: 1.6, canvas: Self.canvas, sampleIntervalSeconds: 0.5)
        let report = try await ScenarioRunner(config: config, factory: CoreRenderPipelineFactory()).run()
        #expect(report.events.switches >= 2)
        #expect(report.events.transitionsCompleted >= 2)
    }

    @Test func playlistScenarioKeepsAtMostTwoItemsLoaded() async throws {
        let config = ScenarioConfig(name: "test-playlist", kind: .playlist(items: 6, itemSeconds: 0.1, loop: true),
                                    durationSeconds: 1.5, canvas: Self.canvas, inputs: 1, sampleIntervalSeconds: 0.5)
        let report = try await ScenarioRunner(config: config, factory: CoreRenderPipelineFactory()).run()
        #expect(report.events.playlistItemsStarted >= 8)
        #expect(report.events.playlistLoops >= 1)
        #expect((1...2).contains(report.events.maxLoadedPlaylistItems))
        #expect(report.events.playlistNotReadyFrames <= 6, "precarga A/B: \(report.events.playlistNotReadyFrames)")
    }

    @Test func playlistReplacesFirstInputWithoutExtraSource() async throws {
        let config = ScenarioConfig(name: "test-inputs", kind: .playlist(items: 3, itemSeconds: 1, loop: false),
                                    durationSeconds: 1, canvas: Self.canvas, inputs: 3)
        let scene = try await Scene.make(config: config, factory: MockPipelineFactory())
        #expect(scene.inputSourceCount == 2)
        scene.tearDown()
    }

    @Test func reportRoundTripsThroughJSON() async throws {
        let config = ScenarioConfig(name: "test-json", kind: .switchEvery(seconds: 1, transition: .cut, fadeSeconds: 0),
                                    durationSeconds: 0.5, canvas: Self.canvas, sampleIntervalSeconds: 0.2)
        let report = try await ScenarioRunner(config: config, factory: MockPipelineFactory()).run()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minimix-stress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try report.write(to: dir)
        #expect(url.lastPathComponent.hasPrefix("test-json-mock-"))
        let decoded = try StressReport.decode(Data(contentsOf: url))
        #expect(decoded.scenario == config)
        #expect(decoded.frames.rendered == report.frames.rendered)
        #expect(decoded.schemaVersion == StressReport.currentSchemaVersion)
    }

    @Test func statsPercentiles() {
        let stats = StressReport.Stats((1...100).map(Double.init))
        #expect(stats.mean == 50.5 && stats.max == 100)
        #expect(stats.p50 == 51 && stats.p95 == 95 && stats.p99 == 99)
        #expect(StressReport.Stats([]).max == 0)
    }

    @Test func builtInScenariosAreCodable() throws {
        for scenario in ScenarioConfig.builtIn {
            let data = try JSONEncoder().encode(scenario)
            #expect(try JSONDecoder().decode(ScenarioConfig.self, from: data) == scenario)
        }
        #expect(ScenarioConfig.named("playlist-50")?.kind == .playlist(items: 50, itemSeconds: 0.5, loop: true))
    }
}
