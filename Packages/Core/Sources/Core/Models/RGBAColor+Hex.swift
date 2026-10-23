// Core/Models/RGBAColor+Hex.swift — conversión de `RGBAColor` desde/hacia hexadecimal (T10).

import Foundation

extension RGBAColor {
    /// Crea un color desde `"#RRGGBB"` o `"#RRGGBBAA"` (el `#` es opcional; mayúsculas o minúsculas).
    /// Devuelve nil si la cadena no tiene 6 u 8 dígitos hexadecimales.
    /// Los componentes se interpretan directamente como valores 0…1 (`0xFF` = 1), sin conversión de gamma.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        func component(_ byte: UInt32) -> Double { Double(byte & 0xFF) / 255 }
        self.init(
            red: component(rgb >> 16),
            green: component(rgb >> 8),
            blue: component(rgb),
            alpha: hasAlpha ? component(value) : 1
        )
    }

    /// `"#RRGGBB"` si el color es opaco (alpha == 1 tras cuantizar); si no, `"#RRGGBBAA"`.
    /// Los componentes se limitan a 0…1 y se redondean al byte más cercano.
    public var hexString: String {
        let alphaByte = Self.byte(alpha)
        return alphaByte == 0xFF ? hexString(includingAlpha: false) : hexString(includingAlpha: true)
    }

    /// Hexadecimal en mayúsculas, con o sin alpha.
    public func hexString(includingAlpha: Bool) -> String {
        var result = "#" + [red, green, blue].map { Self.hexByte(Self.byte($0)) }.joined()
        if includingAlpha { result += Self.hexByte(Self.byte(alpha)) }
        return result
    }

    private static func byte(_ component: Double) -> Int {
        guard component.isFinite else { return 0 }
        return Int((min(max(component, 0), 1) * 255).rounded())
    }

    private static func hexByte(_ value: Int) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[value >> 4], digits[value & 0xF]])
    }
}
