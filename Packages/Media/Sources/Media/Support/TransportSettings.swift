/// Bucle e In/Out de una fuente con transporte (diagnóstico y tests).
struct TransportSettings: Equatable, Sendable {
    var loop: Bool
    var inPoint: Double?
    var outPoint: Double?
}
