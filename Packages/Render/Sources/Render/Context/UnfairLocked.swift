import os

/// Caja con un `OSAllocatedUnfairLock` para estado mutable compartido entre hilos.
/// Pensada para secciones críticas cortas (sin E/S ni esperas dentro).
final class UnfairLocked<Value>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
