import Metal
import os

let renderLog = Logger(subsystem: "MiniMix", category: "Render")

/// Pipelines por formato de píxel. Se compilan solo en `prepare` (configuración);
/// en el hilo de render `pipeline(for:)` solo consulta, y un formato no preparado
/// cuenta como fallo (se registra en el log una vez por formato).
final class PipelineCache: @unchecked Sendable {
    private struct State {
        var pipelines: [UInt: MTLRenderPipelineState] = [:]
        var loggedMisses: Set<UInt> = []
        var misses = 0
    }

    private let state = UnfairLocked(State())
    private let name: String
    private let make: (MTLPixelFormat) throws -> MTLRenderPipelineState

    init(name: String, make: @escaping (MTLPixelFormat) throws -> MTLRenderPipelineState) {
        self.name = name
        self.make = make
    }

    /// Compila (si hace falta) el pipeline de `format`. Puede tardar: no llamar en el hilo de render.
    func prepare(_ format: MTLPixelFormat) throws {
        if state.withLock({ $0.pipelines[format.rawValue] }) != nil { return }
        let pipeline = try make(format)
        state.withLock { $0.pipelines[format.rawValue] = $0.pipelines[format.rawValue] ?? pipeline }
    }

    /// Pipeline ya preparado o nil (y se cuenta el fallo). Nunca compila.
    func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let (pipeline, shouldLog) = state.withLock { st -> (MTLRenderPipelineState?, Bool) in
            if let pipeline = st.pipelines[format.rawValue] { return (pipeline, false) }
            st.misses += 1
            return (nil, st.loggedMisses.insert(format.rawValue).inserted)
        }
        if shouldLog {
            renderLog.error(
                "\(self.name, privacy: .public): no pipeline for pixel format \(format.rawValue); fallback clear")
        }
        return pipeline
    }

    var missCount: Int { state.withLock { $0.misses } }
}

extension MTLCommandBuffer {
    /// Pase que solo limpia `target` con `color` (premultiplicado): respaldo cuando falta un pipeline.
    func encodeClear(_ target: MTLTexture, color: SIMD4<Float>) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: Double(color.w))
        makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
