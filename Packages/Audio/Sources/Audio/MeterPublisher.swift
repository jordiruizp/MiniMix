import Core
import Dispatch

/// Publica los picos (dBFS) de los vúmetros a frecuencia fija desde una cola propia.
///
/// El hilo de audio solo hace `Atomic.max` sobre `RampGainControl`; aquí se leen y ponen a cero
/// (`exchange`) los picos, se convierten a dBFS y se emiten. Así el pico de cada periodo no se
/// pierde aunque haya varios ciclos de render entre dos emisiones.
final class MeterPublisher: Sendable {
    private struct State {
        var sources: [InputID?: RampGainControl] = [:]
        var timer: DispatchSourceTimer?
    }

    private let state = LockedState(State())
    private let continuation: AsyncStream<[InputID?: [Float]]>.Continuation
    private let queue = DispatchQueue(label: "minimix.audio.meters", qos: .userInteractive)
    private let interval: Double

    let stream: AsyncStream<[InputID?: [Float]]>

    init(rate: Double) {
        interval = rate > 0 ? 1 / rate : 0
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        state.withLock { $0.timer?.cancel() }
        continuation.finish()
    }

    func register(_ control: RampGainControl, for id: InputID?) {
        state.withLock { $0.sources[id] = control }
    }

    func unregister(_ id: InputID?) {
        state.withLock { _ = $0.sources.removeValue(forKey: id) }
    }

    func start() {
        state.withLock { state in
            // Frecuencia 0: sin temporizador (los tests publican a mano con `publish()`).
            guard state.timer == nil, interval > 0 else { return }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.publish() }
            timer.resume()
            state.timer = timer
        }
    }

    func stop() {
        state.withLock { state in
            state.timer?.cancel()
            state.timer = nil
        }
    }

    /// Lee los picos acumulados y emite un mensaje (también lo usan los tests).
    func publish() {
        let levels = state.withLock { state in
            state.sources.mapValues { control in control.takePeaks().map(Decibels.fromLinear) }
        }
        continuation.yield(levels)
    }
}
