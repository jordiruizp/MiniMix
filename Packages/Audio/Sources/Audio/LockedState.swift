import os

/// Estado mutable protegido por un cerrojo corto.
///
/// Se usa en lugar de `Synchronization.Mutex` porque `Mutex.withLock` pasa el valor como
/// `inout sending`: con tipos de AVFAudio no `Sendable` (nodos, búferes que llegan como parámetro)
/// el análisis de regiones de Swift 6.3 lo rechaza ("cannot be task-isolated at end of function")
/// aunque Swift 6.4 lo acepte. Aquí no hay transferencia de regiones.
///
/// `@unchecked Sendable`: `value` solo se lee y escribe dentro de `withLock`, serializado por
/// `lock`; ningún acceso escapa del cierre (los valores no `Sendable` no salen del cerrojo salvo
/// en los métodos que lo documentan). No se usa nunca desde el hilo de audio.
final class LockedState<Value>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
