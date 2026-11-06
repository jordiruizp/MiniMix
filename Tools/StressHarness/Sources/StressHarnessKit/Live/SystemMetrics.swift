import Darwin
import Foundation

/// CPU de toda la máquina (0…100) entre dos muestras, con `host_statistics(HOST_CPU_LOAD_INFO)`.
struct SystemCPUMeter {
    private let host = mach_host_self()
    private var last: (busy: UInt64, total: UInt64)?

    mutating func sample() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let now = (busy: user + system + nice, total: user + system + nice + idle)
        defer { last = now }
        guard let last, now.total > last.total else { return nil }
        return Double(now.busy - last.busy) / Double(now.total - last.total) * 100
    }
}

enum ProcessLaunch {
    /// Instante de arranque del proceso (reloj de pared), vía `sysctl(KERN_PROC_PID)`.
    static func startDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}

enum Regression {
    /// Pendiente por mínimos cuadrados de `y` frente a `x` (0 si no hay datos suficientes).
    static func slope(_ points: [(x: Double, y: Double)]) -> Double {
        guard points.count >= 3 else { return 0 }
        let n = Double(points.count)
        let mx = points.map(\.x).reduce(0, +) / n
        let my = points.map(\.y).reduce(0, +) / n
        let sxy = points.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) }
        let sxx = points.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        return sxx > 0 ? sxy / sxx : 0
    }
}

/// El runner del CI de GitHub corre en este mismo Mac: si está activo falsea CPU, GPU y térmica.
enum CIRunner {
    static func isActive() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-q", "-f", "Runner.Worker"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
