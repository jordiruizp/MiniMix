import Core
import SwiftUI

extension RGBAColor {
    /// Crea un color desde `#RRGGBB`, `RRGGBB`, `#RRGGBBAA` o `#RGB`. Componentes 0…1 tal cual
    /// (sin conversión de gamma; ver informe G · T50).
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let base = hasAlpha ? value >> 8 : value
        self.init(
            red: Double((base >> 16) & 0xFF) / 255,
            green: Double((base >> 8) & 0xFF) / 255,
            blue: Double(base & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }

    /// `#RRGGBB` (o `#RRGGBBAA` si el alfa no es 1).
    public var hexString: String {
        func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 1 ? rgb : rgb + String(format: "%02X", byte(alpha))
    }

    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }
}
