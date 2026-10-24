import Foundation
import Testing
@testable import TestSupport

/// Sensibles a la carga de la máquina (otras suites corren en paralelo): umbrales holgados y suite serie.
@Suite("ResourceMeter", .serialized)
struct ResourceMeterTests {
    /// CLAUDE.md: las aserciones de rendimiento (CPU, ritmo de muestreo) solo se exigen fuera de CI.
    static let enforcePerformance = ProcessInfo.processInfo.environment["CI"] == nil

    @Test func footprintGrowsWithTouchedMemory() throws {
        let before = try #require(ProcessMetrics.physFootprint())
        #expect(before > 1_000_000)
        let size = 128 * 1_048_576
        let block = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { block.deallocate() }
        block.initializeMemory(as: UInt8.self, repeating: 0xA5, count: size)
        let after = try #require(ProcessMetrics.physFootprint())
        #expect(after >= before + UInt64(size) / 4, "otras suites pueden liberar memoria a la vez")
        #expect((ProcessMetrics.residentSize() ?? 0) > 0)
    }

    @Test func cpuMeterSeesBusyLoop() {
        var meter = CPUUsageMeter()
        let end = ContinuousClock.now + .milliseconds(300)
        var x = 0.0
        while ContinuousClock.now < end { x += sin(x) + 1 }
        #expect(x > 0)
        let busy = meter.sample()
        print("[perf] CPU en bucle ocupado: \(busy) %")
        #expect(busy >= 0 && busy < 100 * Double(ProcessInfo.processInfo.activeProcessorCount) + 1)
        if Self.enforcePerformance { #expect(busy > 10, "ocupación medida: \(busy) %") }
    }

    @Test func monitorCollectsSamples() async throws {
        let monitor = ResourceMonitor(interval: .milliseconds(50))
        monitor.start()
        try await Task.sleep(for: .milliseconds(600))
        monitor.stop()
        let samples = monitor.samples
        #expect(!samples.isEmpty)
        if Self.enforcePerformance { #expect(samples.count >= 2, "\(samples.count)") }
        #expect(samples.allSatisfy { $0.footprintMB > 1 && ThermalLevel.allCases.contains($0.thermal) })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.t < $1.t })
    }

    @Test func restartingAndStoppingLeavesNoSamplerRunning() async throws {
        let monitor = ResourceMonitor(interval: .milliseconds(20))
        monitor.start()
        monitor.start() // la primera tarea se cancela
        try await Task.sleep(for: .milliseconds(400))
        monitor.stop()
        let count = monitor.samples.count
        // Un solo muestreador: ~20 muestras como mucho (con dos serían ~40).
        // Un solo muestreador: nunca más de ~20 muestras (con dos serían ~40). El mínimo depende del planificador.
        #expect(count <= 24, "\(count)")
        if Self.enforcePerformance { #expect(count >= 2, "\(count)") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.samples.count <= count + 1, "tras stop no sigue muestreando")
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
