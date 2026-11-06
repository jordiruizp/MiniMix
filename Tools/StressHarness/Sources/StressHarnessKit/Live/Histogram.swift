/// Histograma de memoria constante para series largas (horas a 60 fps): media exacta, máximo exacto
/// y percentiles con la resolución de `binWidth`.
public struct Histogram: Sendable {
    public let binWidth: Double
    private var bins: [Int]
    private var overflow: [Double] = []
    public private(set) var sampleCount = 0
    public private(set) var sum = 0.0
    public private(set) var max = 0.0

    public init(binWidth: Double, upperBound: Double) {
        self.binWidth = binWidth
        bins = Array(repeating: 0, count: Int((upperBound / binWidth).rounded(.up)))
    }

    public mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        let v = Swift.max(0, value)
        sampleCount += 1
        sum += v
        max = Swift.max(max, v)
        let index = Int(v / binWidth)
        if index < bins.count {
            bins[index] += 1
        } else if overflow.count < 10_000 {
            overflow.append(v)
        }
    }

    public var mean: Double { sampleCount == 0 ? 0 : sum / Double(sampleCount) }

    /// Percentil `p` (0…1): centro del intervalo que lo contiene (sin pasar del máximo).
    public func percentile(_ p: Double) -> Double {
        guard sampleCount > 0 else { return 0 }
        let rank = Int((Double(sampleCount) * p).rounded(.up))
        var seen = 0
        for (index, n) in bins.enumerated() {
            seen += n
            if seen >= rank { return Swift.min((Double(index) + 0.5) * binWidth, max) }
        }
        let sorted = overflow.sorted()
        let rest = rank - seen
        return sorted.isEmpty ? max : sorted[Swift.min(sorted.count - 1, Swift.max(0, rest - 1))]
    }

    public var stats: StressReport.Stats {
        var stats = StressReport.Stats([])
        stats.mean = mean
        stats.p50 = percentile(0.5)
        stats.p95 = percentile(0.95)
        stats.p99 = percentile(0.99)
        stats.max = max
        return stats
    }
}
