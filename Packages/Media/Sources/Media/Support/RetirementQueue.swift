/// Cola de recursos retirados que se sueltan por tiempo **y** por número.
///
/// Un elemento solo se libera cuando hay más de `minCount` retirados **y** el más
/// antiguo lleva al menos `minAgeNanos` retirado. Así un `CVMetalTexture` sobrevive
/// a los command buffers en vuelo que aún lo leen aunque el render vaya rápido
/// (con 3 fotogramas a 60 Hz serían solo ~50 ms).
struct RetirementQueue<Element> {
    let minCount: Int
    let minAgeNanos: Int64
    private(set) var items: [(element: Element, retiredAt: Int64)] = []

    init(minCount: Int = 3, minAgeNanos: Int64 = 200_000_000) {
        self.minCount = minCount
        self.minAgeNanos = minAgeNanos
    }

    var count: Int { items.count }

    mutating func retire(_ element: Element, now: Int64) {
        items.append((element, now))
        while items.count > minCount, let first = items.first, now - first.retiredAt >= minAgeNanos {
            items.removeFirst()
        }
    }

    mutating func removeAll() { items.removeAll() }
}
