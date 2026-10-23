import Core
import Testing
@testable import Render

@Suite("RenderStatsCollector")
struct RenderStatsTests {
    @Test func steadySixtyFps() {
        let collector = RenderStatsCollector(frameRate: .fps60)
        for i in 0..<60 { collector.frameSubmitted(at: 100 + Double(i) / 60) }
        let stats = collector.stats
        #expect(abs(stats.fps - 60) < 0.5)
        #expect(stats.droppedFrames == 0)
    }

    @Test func detectsGapsAndIgnoresPauses() {
        let collector = RenderStatsCollector(frameRate: .fps60)
        collector.frameSubmitted(at: 0)
        collector.frameSubmitted(at: 1.0 / 60)
        collector.frameSubmitted(at: 4.0 / 60) // faltan 2
        #expect(collector.stats.droppedFrames == 2)
        collector.frameSubmitted(at: 10) // pausa larga: no cuenta
        #expect(collector.stats.droppedFrames == 2)
        collector.reportDropped(3)
        #expect(collector.stats.droppedFrames == 5)
        collector.reset()
        #expect(collector.stats == RenderStats())
    }

    @Test func gpuTimeAverage() {
        let collector = RenderStatsCollector()
        collector.gpuFrameCompleted(gpuTime: 0.002)
        #expect(abs(collector.stats.gpuTimeMs - 2) < 1e-9)
        collector.gpuFrameCompleted(gpuTime: .nan)
        for _ in 0..<200 { collector.gpuFrameCompleted(gpuTime: 0.004) }
        #expect(abs(collector.stats.gpuTimeMs - 4) < 0.01)
    }
}
