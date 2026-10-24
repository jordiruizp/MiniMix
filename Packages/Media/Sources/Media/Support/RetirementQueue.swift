/// Cola de recursos retirados (fotogramas ya sustituidos que la GPU aún puede leer).
///
/// Reglas (con el contrato de ≤ 3 command buffers en vuelo, ver `VideoInput`):
/// - Al retirar: se suelta el más antiguo si hay más de `minCount` **y** tiene al
///   menos `minAgeNanos`; y siempre que haya más de `maxCount` (tope duro de memoria).
/// - `prune(now:)` (sin fotograma nuevo): suelta todo lo que tenga ≥ `minAgeNanos`,
///   aunque queden menos de `minCount` (ningún command buffer nuevo los referencia).
/// - `removeAll()`: vaciado al pausar/ocultar (tras un margen, lo programa `VideoInput`).
///
/// Con 1080p BGRA (8,3 MB por fotograma) el tope de 6 limita lo retenido por entrada
/// activa a ~50 MB (+ el fotograma actual); en pausa u oculta, a solo el actual.
struct RetirementQueue<Element> {
    let minCount: Int
    let maxCount: Int
    let minAgeNanos: Int64
    private(set) var items: [(element: Element, retiredAt: Int64)] = []

    init(minCount: Int = 3, maxCount: Int = 6, minAgeNanos: Int64 = 100_000_000) {
        self.minCount = minCount
        self.maxCount = max(maxCount, minCount)
        self.minAgeNanos = minAgeNanos
    }

    var count: Int { items.count }

    mutating func retire(_ element: Element, now: Int64) {
        items.append((element, now))
        while items.count > maxCount { items.removeFirst() }
        while items.count > minCount, let first = items.first, now - first.retiredAt >= minAgeNanos {
            items.removeFirst()
        }
    }

    /// Poda por edad sin fotograma nuevo.
    mutating func prune(now: Int64) {
        while let first = items.first, now - first.retiredAt >= minAgeNanos { items.removeFirst() }
    }

    mutating func removeAll() { items.removeAll() }
}
