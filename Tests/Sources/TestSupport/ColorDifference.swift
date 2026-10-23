import Foundation

/// Color CIELAB (D65).
public struct LabColor: Equatable, Sendable {
    public var l, a, b: Double
    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// Desde sRGB 8 bit (con gamma), iluminante D65.
    public init(srgbRed r: UInt8, green g: UInt8, blue b: UInt8) {
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
        let y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let (fx, fy, fz) = (f(x), f(y), f(z))
        self.init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }
}

public enum DeltaE: String, Sendable, CaseIterable {
    case cie76, ciede2000

    public func difference(_ lhs: LabColor, _ rhs: LabColor) -> Double {
        switch self {
        case .cie76: Self.cie76(lhs, rhs)
        case .ciede2000: Self.ciede2000(lhs, rhs)
        }
    }

    public static func cie76(_ lhs: LabColor, _ rhs: LabColor) -> Double {
        let dl = lhs.l - rhs.l
        let da = lhs.a - rhs.a
        let db = lhs.b - rhs.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// CIEDE2000 (Sharma, Wu, Dalal 2005), kL = kC = kH = 1.
    public static func ciede2000(_ lhs: LabColor, _ rhs: LabColor) -> Double {
        let rad = Double.pi / 180
        let c1 = hypot(lhs.a, lhs.b)
        let c2 = hypot(rhs.a, rhs.b)
        let cMean = (c1 + c2) / 2
        let c7 = pow(cMean, 7)
        let g = 0.5 * (1 - (c7 / (c7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * lhs.a
        let a2p = (1 + g) * rhs.a
        let c1p = hypot(a1p, lhs.b)
        let c2p = hypot(a2p, rhs.b)
        func hue(_ b: Double, _ ap: Double) -> Double {
            guard b != 0 || ap != 0 else { return 0 }
            let h = atan2(b, ap) / rad
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(lhs.b, a1p)
        let h2p = hue(rhs.b, a2p)

        let dLp = rhs.l - lhs.l
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp / 2 * rad)

        let lMean = (lhs.l + rhs.l) / 2
        let cpMean = (c1p + c2p) / 2
        var hpMean = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 {
                hpMean /= 2
            } else {
                hpMean = h1p + h2p < 360 ? (hpMean + 360) / 2 : (hpMean - 360) / 2
            }
        }
        let t = 1 - 0.17 * cos((hpMean - 30) * rad) + 0.24 * cos(2 * hpMean * rad)
            + 0.32 * cos((3 * hpMean + 6) * rad) - 0.20 * cos((4 * hpMean - 63) * rad)
        let dTheta = 30 * exp(-pow((hpMean - 275) / 25, 2))
        let cp7 = pow(cpMean, 7)
        let rc = 2 * (cp7 / (cp7 + pow(25, 7))).squareRoot()
        let l50 = (lMean - 50) * (lMean - 50)
        let sl = 1 + 0.015 * l50 / (20 + l50).squareRoot()
        let sc = 1 + 0.045 * cpMean
        let sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta * rad) * rc
        let tl = dLp / sl
        let tc = dCp / sc
        let th = dHp / sh
        return (tl * tl + tc * tc + th * th + rt * tc * th).squareRoot()
    }
}

/// Comparación perceptual de dos imágenes del mismo tamaño (snapshots).
public struct ImageDifference: Equatable, Sendable {
    public var meanDeltaE: Double
    public var maxDeltaE: Double
    /// Percentil 99 de ΔE.
    public var p99DeltaE: Double
    /// Fracción de píxeles muestreados con ΔE > `pixelThreshold`.
    public var fractionAboveThreshold: Double
    /// Máxima diferencia absoluta de alfa (0…255).
    public var maxAlphaDifference: Int
    public var sampledPixels: Int

    /// Compara `actual` con `expected`. `stride` > 1 submuestrea para acelerar tests grandes.
    public static func compare(_ actual: RGBAImage, _ expected: RGBAImage, metric: DeltaE = .ciede2000,
                               pixelThreshold: Double = 2.3, stride: Int = 1) -> ImageDifference? {
        guard actual.width == expected.width, actual.height == expected.height, stride >= 1 else { return nil }
        var values: [Double] = []
        values.reserveCapacity((actual.width / stride + 1) * (actual.height / stride + 1))
        var maxAlpha = 0
        var cache: [UInt32: LabColor] = [:]
        func lab(_ p: RGBAImage.Pixel) -> LabColor {
            let key = UInt32(p.r) << 16 | UInt32(p.g) << 8 | UInt32(p.b)
            if let hit = cache[key] { return hit }
            let value = LabColor(srgbRed: p.r, green: p.g, blue: p.b)
            cache[key] = value
            return value
        }
        for y in Swift.stride(from: 0, to: actual.height, by: stride) {
            for x in Swift.stride(from: 0, to: actual.width, by: stride) {
                let pa = actual[x, y]
                let pe = expected[x, y]
                maxAlpha = max(maxAlpha, abs(Int(pa.a) - Int(pe.a)))
                values.append(pa == pe ? 0 : metric.difference(lab(pa), lab(pe)))
            }
        }
        let sorted = values.sorted()
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        return ImageDifference(
            meanDeltaE: values.reduce(0, +) / Double(values.count), maxDeltaE: sorted.last ?? 0, p99DeltaE: p99,
            fractionAboveThreshold: Double(values.filter { $0 > pixelThreshold }.count) / Double(values.count),
            maxAlphaDifference: maxAlpha, sampledPixels: values.count)
    }

    /// Criterio típico de snapshot: ΔE medio y p99 por debajo de los umbrales (2,3 ≈ JND).
    public func isWithin(mean: Double = 1.0, p99: Double = 2.3, alpha: Int = 2) -> Bool {
        meanDeltaE <= mean && p99DeltaE <= p99 && maxAlphaDifference <= alpha
    }
}
