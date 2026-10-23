import Darwin
import Foundation

/// Métricas reales del proceso para la barra de estado.
public enum ProcessMetrics {
    /// Huella física del proceso (lo que muestra el Monitor de Actividad), vía `task_info`.
    public static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    public static var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

extension ProcessInfo.ThermalState {
    public var label: String {
        switch self {
        case .nominal: "OK"
        case .fair: "Moderado"
        case .serious: "Alto"
        case .critical: "Crítico"
        @unknown default: "?"
        }
    }
}
