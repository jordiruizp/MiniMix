import AppKit
import SwiftUI

/// Colores semánticos de MiniMix (T91). Se adaptan a claro/oscuro y al aumento de contraste:
/// PVW verde y PGM rojo mantienen un contraste ≥ 4,5:1 con texto blanco en ambos modos.
public enum Theme {
    /// Verde de Preview (bordes, cabeceras).
    public static let preview = Color(nsColor: dynamic(
        light: NSColor(srgbRed: 0.05, green: 0.47, blue: 0.20, alpha: 1),
        dark: NSColor(srgbRed: 0.08, green: 0.50, blue: 0.22, alpha: 1)))
    /// Rojo de Programa.
    public static let program = Color(nsColor: dynamic(
        light: NSColor(srgbRed: 0.74, green: 0.08, blue: 0.08, alpha: 1),
        dark: NSColor(srgbRed: 0.80, green: 0.15, blue: 0.13, alpha: 1)))
    /// Avisos (térmico, decodificadores, 4K).
    public static let warning = Color(nsColor: dynamic(
        light: NSColor(srgbRed: 0.62, green: 0.36, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.25, alpha: 1)))
    /// Errores graves (térmico crítico).
    public static let critical = program

    /// Componentes sRGB de un color de tema en una apariencia (tests de contraste).
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double
    }

    static func components(_ color: Color, dark: Bool) -> RGB {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var result = RGB(red: 0, green: 0, blue: 0)
        appearance.performAsCurrentDrawingAppearance {
            let ns = (NSColor(color).usingColorSpace(.sRGB) ?? .black)
            result = RGB(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
        }
        return result
    }

    /// Relación de contraste WCAG entre un color de tema y el blanco.
    static func contrastWithWhite(_ color: Color, dark: Bool) -> Double {
        let rgb = components(color, dark: dark)
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
        return 1.05 / (luminance + 0.05)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
