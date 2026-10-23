import Core

public extension FitMode {
    /// Rectángulo que ocupa una fuente de tamaño `source` dentro de un destino
    /// `destination`, en coordenadas normalizadas del destino (origen arriba-izquierda):
    /// `(x, y, ancho, alto)`.
    ///
    /// - `fit`: cabe entera (letterbox/pillarbox); el resto queda transparente.
    /// - `fill`: cubre todo el destino conservando el aspecto (recorta lo que sobra).
    /// - `stretch`: ocupa el destino deformando la fuente.
    func normalizedRect(source: PixelSize, destination: PixelSize) -> SIMD4<Float> {
        guard self != .stretch, source.width > 0, source.height > 0,
              destination.width > 0, destination.height > 0 else { return SIMD4(0, 0, 1, 1) }
        let sourceAspect = Double(source.width) / Double(source.height)
        let destAspect = Double(destination.width) / Double(destination.height)
        let ratio = sourceAspect / destAspect
        let width: Double
        let height: Double
        switch self {
        case .fit:
            (width, height) = ratio > 1 ? (1, 1 / ratio) : (ratio, 1)
        case .fill:
            (width, height) = ratio > 1 ? (ratio, 1) : (1, 1 / ratio)
        case .stretch:
            (width, height) = (1, 1)
        }
        return SIMD4(Float((1 - width) / 2), Float((1 - height) / 2), Float(width), Float(height))
    }
}
