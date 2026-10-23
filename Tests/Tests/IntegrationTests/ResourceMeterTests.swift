import Foundation
import Testing
@testable import TestSupport

@Suite("ResourceMeter", .serialized)
struct ResourceMeterTests {
    @Test func footprintGrowsWithTouchedMemory() throws {
        let before = try #require(ProcessMetrics.physFootprint())
        #expect(before > 1_000_000)
        let size = 64 * 1_048_576
        let block = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { block.deallocate() }
        block.initializeMemory(as: UInt8.self, repeating: 0xA5, count: size)
        let after = try #require(ProcessMetrics.physFootprint())
        #expect(after >= before + UInt64(size) / 2)
        #expect((ProcessMetrics.residentSize() ?? 0) > 0)
    }

    @Test func cpuMeterSeesBusyLoop() {
        var meter = CPUUsageMeter()
        let end = ContinuousClock.now + .milliseconds(300)
        var x = 0.0
        while ContinuousClock.now < end { x += sin(x) + 1 }
        #expect(x > 0)
        let busy = meter.sample()
        #expect(busy > 25, "ocupación medida: \(busy) %")
        #expect(busy < 100 * Double(ProcessInfo.processInfo.activeProcessorCount) + 1)
    }

    @Test func monitorCollectsSamples() async throws {
        let monitor = ResourceMonitor(interval: .milliseconds(50))
        monitor.start()
        try await Task.sleep(for: .milliseconds(400))
        monitor.stop()
        let samples = monitor.samples
        #expect(samples.count >= 3)
        #expect(samples.allSatisfy { $0.footprintMB > 1 && ThermalLevel.allCases.contains($0.thermal) })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.t < $1.t })
    }

    @Test func machineInfoIsPopulated() throws {
        let info = MachineInfo.current()
        #expect(info.memoryGB > 1)
        #expect(info.logicalCPUs > 0)
        #expect(!info.osVersion.isEmpty)
        let json = try JSONEncoder().encode(info)
        #expect(try JSONDecoder().decode(MachineInfo.self, from: json) == info)
    }

    @Test func thermalLevelsAreOrdered() {
        #expect(ThermalLevel.nominal < .fair && ThermalLevel.serious < .critical)
    }
}
