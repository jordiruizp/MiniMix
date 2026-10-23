import os

/// Estado mutable protegido por un `OSAllocatedUnfairLock` corto.
///
/// `@unchecked Sendable` justificado: todo acceso a `value` pasa por el cerrojo.
/// Existe (en lugar de `OSAllocatedUnfairLock<State>` o `Mutex`) porque parte del
/// estado son objetos de Metal/CoreVideo/AVFAudio sin anotar como `Sendable`
/// (`MTLTexture`, `CVMetalTexture`…) que sí son seguros entre hilos para
/// retener/leer, y necesitamos devolverlos fuera de la sección crítica
/// (p. ej. la textura de `texture(for:)`).
final class LockedState<Value>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    @inline(__always)
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}
