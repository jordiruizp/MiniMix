import Darwin
import Foundation

/// Medidas instantáneas del proceso actual (memoria, CPU, térmica) y de la máquina.
public enum ProcessMetrics {
    /// `phys_footprint` (lo que muestra el Monitor de Actividad como «Memoria»), en bytes.
    public static func physFootprint() -> UInt64? { vmInfo()?.phys_footprint }

    /// Tamaño residente (RSS), en bytes.
    public static func residentSize() -> UInt64? { vmInfo().map { UInt64($0.resident_size) } }

    /// Tiempo de CPU (usuario + sistema) consumido por todos los hilos del proceso, en segundos.
    public static func cpuTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    public static var thermalState: ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}

/// `ProcessInfo.ThermalState` en forma codificable.
public enum ThermalLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case nominal, fair, serious, critical, unknown

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }
}

/// Porcentaje de CPU del proceso entre dos muestras (100 = un núcleo completo).
public struct CPUUsageMeter: Sendable {
    private var lastCPU: Double
    private var lastWall: ContinuousClock.Instant

    public init() {
        lastCPU = ProcessMetrics.cpuTime()
        lastWall = .now
    }

    public mutating func sample() -> Double {
        let cpu = ProcessMetrics.cpuTime()
        let wall = ContinuousClock.Instant.now
        let elapsed = lastWall.duration(to: wall)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        defer {
            lastCPU = cpu
            lastWall = wall
        }
        return seconds > 0 ? (cpu - lastCPU) / seconds * 100 : 0
    }
}

/// Una muestra temporal de recursos.
public struct ResourceSample: Codable, Equatable, Sendable {
    /// Segundos desde el inicio de la medida.
    public var t: Double
    public var footprintMB: Double
    public var residentMB: Double
    public var cpuPercent: Double
    public var thermal: ThermalLevel
}

/// Muestreador periódico (en un `Task` propio, fuera del hilo de render).
public final class ResourceMonitor: Sendable {
    private let state = LockedBox<[ResourceSample]>([])
    private let task = LockedBox<Task<Void, Never>?>(nil)
    public let interval: Duration

    public init(interval: Duration = .seconds(1)) { self.interval = interval }

    public func start() {
        let interval = interval
        let state = state
        let newTask = Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            var cpu = CPUUsageMeter()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let elapsed = start.duration(to: .now)
                let mb = 1.0 / 1_048_576
                let sample = ResourceSample(
                    t: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
                    footprintMB: Double(ProcessMetrics.physFootprint() ?? 0) * mb,
                    residentMB: Double(ProcessMetrics.residentSize() ?? 0) * mb,
                    cpuPercent: cpu.sample(), thermal: ProcessMetrics.thermalState)
                state.withLock { $0.append(sample) }
            }
        }
        task.withLock { $0 = newTask }
    }

    public func stop() {
        task.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    public var samples: [ResourceSample] { state.withLock { $0 } }
}

/// Metadatos de la máquina y del sistema para los informes.
public struct MachineInfo: Codable, Equatable, Sendable {
    public var model: String
    public var chip: String
    public var memoryGB: Double
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var logicalCPUs: Int
    public var osVersion: String
    public var lowPowerMode: Bool

    public static func current() -> MachineInfo {
        let info = ProcessInfo.processInfo
        return MachineInfo(
            model: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            memoryGB: Double(info.physicalMemory) / 1_073_741_824,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? 0,
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
            logicalCPUs: info.activeProcessorCount,
            osVersion: info.operatingSystemVersionString,
            lowPowerMode: info.isLowPowerModeEnabled)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

/// Caja con cerrojo corto para estado compartido en utilidades `Sendable`.
public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
