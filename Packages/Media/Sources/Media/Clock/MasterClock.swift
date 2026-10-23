import Core
import Foundation
import os

/// Reloj maestro de MiniMix (T30).
///
/// - `now`: reloj del host (`CMClockGetHostTimeClock`), en segundos.
/// - `ticks`: un valor por fotograma del proyecto con el **tiempo del fotograma**
///   (`t0 + n · den/num`, aritmética entera), no «ahora». Si el consumidor o el
///   sistema llegan tarde se emite solo el fotograma más reciente y se cuenta
///   el salto en `stats.skippedTicks`.
/// - Fuente de despertares: `CADisplayLink` (si hay pantalla) o un temporizador
///   de alta precisión (headless/tests).
/// - `setFrameRate(_:)` cambia la cadencia en caliente: la rejilla nueva se ancla
///   en el siguiente límite de fotograma de la antigua (sin saltos ni retrocesos).
///
/// Cada acceso a `ticks` crea una suscripción independiente (multicast) con
/// `bufferingNewest(1)`. `stop()` termina las suscripciones activas.
public final class MasterClock: MasterClockProtocol {
    public enum TickSource: Sendable, Equatable {
        /// `CADisplayLink` si hay pantalla; si no, temporizador.
        case automatic
        case displayLink
        case timer
    }

    public struct Stats: Sendable, Equatable {
        public var emittedTicks: Int = 0
        /// Fotogramas de la rejilla que no se emitieron por llegar tarde.
        public var skippedTicks: Int = 0
    }

    private struct State {
        var rate: FrameRate
        var grid: FrameGrid?
        var lastIndex: Int64 = -1
        var running = false
        var stats = Stats()
        var subscribers: [UUID: AsyncStream<HostTime>.Continuation] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>
    private let driver: any TickDriver
    public let tickSource: TickSource

    public init(frameRate: FrameRate = .fps60, tickSource: TickSource = .automatic) {
        precondition(frameRate.numerator > 0 && frameRate.denominator > 0, "FrameRate inválido")
        state = OSAllocatedUnfairLock(initialState: State(rate: frameRate))
        let resolved: TickSource = switch tickSource {
        case .automatic: DisplayLinkTickDriver.hasDisplay ? .displayLink : .timer
        default: tickSource
        }
        self.tickSource = resolved
        driver = resolved == .displayLink ? DisplayLinkTickDriver() : TimerTickDriver()
    }

    deinit { driver.stop() }

    public var frameRate: FrameRate { state.withLock { $0.rate } }

    public var now: HostTime { HostClock.hostTime(nanos: HostClock.nowNanos()) }

    public var stats: Stats { state.withLock { $0.stats } }

    public var isRunning: Bool { state.withLock { $0.running } }

    public var ticks: AsyncStream<HostTime> {
        let (stream, continuation) = AsyncStream.makeStream(of: HostTime.self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: key) }
        }
        state.withLock { $0.subscribers[key] = continuation }
        return stream
    }

    public func start() {
        let shouldStart = state.withLock { s -> Bool in
            guard !s.running else { return false }
            s.running = true
            s.grid = nil
            s.lastIndex = -1
            return true
        }
        guard shouldStart else { return }
        let offGrid = driver.firesOffGrid
        driver.start { [weak self] nowNanos in
            self?.fire(nowNanos: nowNanos, offGrid: offGrid) ?? nowNanos + 1_000_000_000
        }
    }

    public func stop() {
        driver.stop()
        let subscribers = state.withLock { s -> [AsyncStream<HostTime>.Continuation] in
            s.running = false
            defer { s.subscribers.removeAll() }
            return Array(s.subscribers.values)
        }
        subscribers.forEach { $0.finish() }
    }

    /// Cambia la frecuencia del proyecto en caliente.
    public func setFrameRate(_ rate: FrameRate) {
        precondition(rate.numerator > 0 && rate.denominator > 0, "FrameRate inválido")
        state.withLock { s in
            guard s.rate != rate else { return }
            s.rate = rate
            guard let grid = s.grid else { return }
            // El fotograma en curso conserva su duración; el nuevo n = 0 empieza
            // en el siguiente límite de la rejilla antigua.
            let anchor = grid.startNanos(ofIndex: s.lastIndex + 1)
            s.grid = FrameGrid(rate: rate, anchorNanos: anchor)
            s.lastIndex = -1
        }
    }

    /// Lógica de un disparo del driver: emite el fotograma actual si es nuevo y
    /// devuelve el inicio del siguiente.
    private func fire(nowNanos: Int64, offGrid: Bool) -> Int64 {
        typealias Emission = (time: HostTime, to: [AsyncStream<HostTime>.Continuation])
        let (next, emit) = state.withLock { s -> (Int64, Emission?) in
            guard s.running else { return (nowNanos + 1_000_000_000, nil) }
            let grid = s.grid ?? {
                let probe = FrameGrid(rate: s.rate, anchorNanos: nowNanos)
                // Con vsync: anclar medio fotograma antes para que los disparos
                // caigan en mitad del fotograma y el jitter no cambie el índice.
                let anchor = offGrid ? nowNanos - probe.frameNanos / 2 : nowNanos
                return FrameGrid(rate: s.rate, anchorNanos: anchor)
            }()
            s.grid = grid
            let index = grid.index(atNanos: nowNanos)
            var emission: Emission?
            if index > s.lastIndex {
                if s.lastIndex >= 0 { s.stats.skippedTicks += Int(index - s.lastIndex - 1) }
                s.lastIndex = index
                s.stats.emittedTicks += 1
                emission = (HostClock.hostTime(nanos: grid.startNanos(ofIndex: index)), Array(s.subscribers.values))
            }
            return (grid.startNanos(ofIndex: max(index, s.lastIndex) + 1), emission)
        }
        if let emit {
            for continuation in emit.to { continuation.yield(emit.time) }
        }
        return next
    }
}
