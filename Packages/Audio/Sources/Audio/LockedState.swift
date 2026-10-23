import os

/// Estado mutable protegido por un cerrojo corto.
///
/// Se usa en lugar de `Synchronization.Mutex` porque `Mutex.withLock` pasa el valor como
/// `inout sending`: con tipos de AVFAudio no `Sendable` (nodos, búferes que llegan como parámetro)
/// el análisis de regiones de Swift 6.3 lo rechaza ("cannot be task-isolated at end of function")
/// aunque Swift 6.4 lo acepte. Aquí no hay transferencia de regiones.
///
/// `@unchecked Sendable`: `value` solo se lee y escribe dentro de `withLock`, serializado por
/// `lock`; ningún acceso escapa del cierre. `withLock` exige un resultado `Sendable`; las
/// excepciones usan `withLockUnchecked` y lo justifican en la llamada. No se usa nunca desde el hilo de audio.
final class LockedState<Value>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// El resultado debe ser `Sendable`: ningún valor no `Sendable` del estado sale del cerrojo.
    func withLock<Result: Sendable>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try withLockUnchecked(body)
    }

    /// Variante sin restricción para las excepciones documentadas en cada llamada (p. ej. un
    /// `AVAudioFormat`, inmutable tras su creación).
    func withLockUnchecked<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
