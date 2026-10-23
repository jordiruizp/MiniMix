import Core
import Foundation

/// Acumula estadísticas del render (fps, fotogramas perdidos, tiempo GPU) para
/// la barra de estado. Thread-safe; todas las operaciones son O(ventana) con
/// un cerrojo corto.
///
/// Un fotograma se cuenta como perdido cuando el intervalo entre dos envíos
/// supera 1,5 × la duración de fotograma (se cuentan los huecos enteros). Los
/// huecos de más de `resetGap` segundos (render detenido) no cuentan.
public final class RenderStatsCollector: @unchecked Sendable {
    private struct State {
        var submissions: [Double] = []
        var lastSubmission: Double?
        var dropped = 0
        var gpuTimeMs: Double = 0
        var gpuSamples = 0
    }

    public let frameRate: FrameRate
    public let window: Double
    public let resetGap: Double
    private let state = UnfairLocked(State())

    public init(frameRate: FrameRate = .fps60, window: Double = 1, resetGap: Double = 1) {
        self.frameRate = frameRate
        self.window = window
        self.resetGap = resetGap
    }

    /// Registra el envío de un fotograma en `seconds` (reloj monotónico del host).
    public func frameSubmitted(at seconds: Double) {
        let duration = frameRate.frameDuration
        state.withLock { st in
            if let last = st.lastSubmission {
                let gap = seconds - last
                if gap > 1.5 * duration, gap <= resetGap {
                    st.dropped += max(0, Int((gap / duration).rounded()) - 1)
                }
            }
            st.lastSubmission = seconds
            st.submissions.append(seconds)
            let cutoff = seconds - window
            if let firstKept = st.submissions.firstIndex(where: { $0 >= cutoff }), firstKept > 0 {
                st.submissions.removeFirst(firstKept)
            }
        }
    }

    /// Registra el tiempo de GPU de un fotograma (gpuEndTime − gpuStartTime, en segundos).
    public func gpuFrameCompleted(gpuTime: Double) {
        guard gpuTime.isFinite, gpuTime >= 0 else { return }
        state.withLock { st in
            let ms = gpuTime * 1000
            // Media móvil exponencial (~16 fotogramas); la primera muestra la inicializa.
            st.gpuTimeMs = st.gpuSamples == 0 ? ms : st.gpuTimeMs + (ms - st.gpuTimeMs) / 16
            st.gpuSamples += 1
        }
    }

    /// Fotogramas perdidos que detecta otra capa (p. ej. tick del reloj sin render).
    public func reportDropped(_ count: Int = 1) {
        state.withLock { $0.dropped += max(0, count) }
    }

    public func reset() {
        state.withLock { $0 = State() }
    }

    public var stats: RenderStats {
        state.withLock { st in
            var fps = 0.0
            if st.submissions.count > 1, let first = st.submissions.first, let last = st.submissions.last,
               last > first {
                fps = Double(st.submissions.count - 1) / (last - first)
            }
            return RenderStats(fps: fps, droppedFrames: st.dropped, gpuTimeMs: st.gpuTimeMs)
        }
    }

    static func hostSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }
}
