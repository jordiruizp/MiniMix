import Core
import Darwin
import Foundation
import Metal
import Testing
@testable import Media
import Render

enum GPU {
    static let context: MetalContext? = MetalContext.shared
    static var available: Bool { context != nil }
}

/// Espera el primer evento que cumpla `predicate` (o nil si vence el plazo).
func firstEvent(_ stream: AsyncStream<SourceEvent>, timeout: Double = 5,
                where predicate: @escaping @Sendable (SourceEvent) -> Bool) async -> SourceEvent? {
    await withTaskGroup(of: SourceEvent?.self) { group in
        group.addTask {
            for await event in stream where predicate(event) { return event }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Sondea `texture(for:)` con el reloj del host hasta obtener textura.
func waitForTexture(_ source: FrameSource, timeout: Double = 3) async -> MTLTexture? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let texture = source.texture(for: HostClock.hostTime(nanos: HostClock.nowNanos())) { return texture }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

/// Tiempo de CPU (usuario + sistema) consumido por el proceso, en segundos.
func processCPUTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + system
}

/// % de un núcleo que consume el proceso durante `seconds`.
func measureCPU(seconds: Double) async -> Double {
    let cpu0 = processCPUTime()
    let wall0 = Date()
    try? await Task.sleep(for: .seconds(seconds))
    return (processCPUTime() - cpu0) / Date().timeIntervalSince(wall0) * 100
}

/// Objetivos de rendimiento (drops, deriva, CPU, latencias): siempre se miden y se
/// escriben, pero solo se exigen fuera del CI (los runners macOS son VMs con GPU
/// paravirtualizada; ver CLAUDE.md).
enum PerfGate {
    static var enforced: Bool { ProcessInfo.processInfo.environment["CI"] == nil }

    /// Comprueba `condition` solo si se exigen objetivos; en CI lo deja escrito.
    static func check(_ condition: Bool, _ what: String,
                      sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        if enforced {
            #expect(condition, "\(what)", sourceLocation: sourceLocation)
        } else if !condition {
            print("[perf] CI: objetivo no exigido, no cumplido: \(what)")
        }
    }
}

/// Carga del sistema: la máquina de desarrollo la comparten varios agentes.
enum SystemLoad {
    static var oneMinute: Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    /// Más procesos ejecutables que núcleos: las medidas de tiempo real no son fiables.
    static var isOverloaded: Bool { oneMinute > Double(ProcessInfo.processInfo.activeProcessorCount) }

    static var description: String {
        String(format: "%.1f (núcleos %d)", oneMinute, ProcessInfo.processInfo.activeProcessorCount)
    }
}
