import Core
import SwiftUI

/// Puentes entre `RGBAColor` y SwiftUI. El hexadecimal (`init?(hex:)`, `hexString`) está en Core.
extension RGBAColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }
}
