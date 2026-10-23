import AppKit
import CoreGraphics
import Dispatch
import Foundation
import os
import QuartzCore

/// Fuente de «despertares» del `MasterClock`. El reloj decide qué fotograma toca;
/// el driver solo le avisa.
protocol TickDriver: AnyObject, Sendable {
    /// `onFire(nowNanos)` devuelve el siguiente instante (ns del host) en que el
    /// reloj querría ser despertado. Los drivers ligados a la pantalla lo ignoran.
    func start(_ onFire: @escaping @Sendable (Int64) -> Int64)
    func stop()
    /// true si los disparos no están alineados con la rejilla (vsync): el reloj
    /// ancla entonces la rejilla medio fotograma antes del primer disparo para
    /// que el jitter no haga saltar/duplicar índices.
    var firesOffGrid: Bool { get }
}

/// Temporizador de alta precisión: un `DispatchSourceTimer` estricto, sin margen,
/// en una cola de prioridad `userInteractive`, reprogramado a cada fotograma para
/// el instante exacto que pide la rejilla (sin intervalo repetitivo que derive).
final class TimerTickDriver: TickDriver {
    private let queue = DispatchQueue(label: "minimix.clock.timer", qos: .userInteractive)
    private let timer = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)

    var firesOffGrid: Bool { false }

    func start(_ onFire: @escaping @Sendable (Int64) -> Int64) {
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.setEventHandler { [weak source] in
            let next = onFire(HostClock.nowNanos())
            source?.schedule(deadline: DispatchTime(uptimeNanoseconds: UInt64(max(next, 0))),
                             repeating: .never, leeway: .nanoseconds(0))
        }
        source.schedule(deadline: .now(), repeating: .never, leeway: .nanoseconds(0))
        let previous = timer.withLock { current -> DispatchSourceTimer? in
            defer { current = source }
            return current
        }
        previous?.cancel()
        source.activate()
    }

    func stop() {
        timer.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}

/// `CADisplayLink` de macOS 14+ (`NSScreen.displayLink`) servido en un hilo propio
/// (no en el principal, que es de la interfaz). Si no hay pantalla, cae al
/// `TimerTickDriver`.
///
/// `@unchecked Sendable` justificado: `CADisplayLink`, `RunLoop` y `Thread` no son
/// `Sendable`. El enlace se crea en el main actor (exigencia de AppKit), se
/// registra en el run loop del hilo propio (uso documentado de
/// `add(to:forMode:)`) y después solo se toca bajo `state`.
final class DisplayLinkTickDriver: NSObject, TickDriver, @unchecked Sendable {
    private struct State {
        var link: CADisplayLink?
        var onFire: (@Sendable (Int64) -> Int64)?
        var thread: Thread?
        var generation = 0
        var usingFallback = false
    }

    private let state = LockedState(State())
    private let fallback = TimerTickDriver()

    var firesOffGrid: Bool { !state.withLock { $0.usingFallback } }

    /// true si hay al menos una pantalla activa (consulta segura fuera del main actor).
    static var hasDisplay: Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }

    func start(_ onFire: @escaping @Sendable (Int64) -> Int64) {
        stop()
        guard Self.hasDisplay else {
            state.withLock { $0.usingFallback = true }
            fallback.start(onFire)
            return
        }
        let generation = state.withLock { s -> Int in
            s.onFire = onFire
            s.usingFallback = false
            s.generation += 1
            return s.generation
        }
        let thread = Thread { [weak self] in self?.runLoopThread(generation: generation) }
        thread.name = "minimix.clock.displaylink"
        thread.qualityOfService = .userInteractive
        state.withLock { $0.thread = thread }
        thread.start()
    }

    func stop() {
        let (link, thread) = state.withLock { s -> (CADisplayLink?, Thread?) in
            defer {
                s.link = nil
                s.thread = nil
                s.onFire = nil
                s.generation += 1
            }
            return (s.link, s.thread)
        }
        link?.invalidate()
        thread?.cancel()
        fallback.stop()
    }

    private func runLoopThread(generation: Int) {
        // Una fuente de puerto mantiene vivo el run loop mientras esperamos al enlace.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        // RunLoop no es Sendable; registrar un CADisplayLink en el run loop de otro
        // hilo es precisamente el uso documentado de `add(to:forMode:)`.
        nonisolated(unsafe) let runLoop = RunLoop.current
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.installLink(on: runLoop, generation: generation) }
        }
        while !Thread.current.isCancelled {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
        }
    }

    @MainActor
    private func installLink(on runLoop: RunLoop, generation: Int) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            let onFire = state.withLock { s -> (@Sendable (Int64) -> Int64)? in
                guard s.generation == generation else { return nil }
                s.usingFallback = true
                return s.onFire
            }
            if let onFire { fallback.start(onFire) }
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        let installed = state.withLock { s -> Bool in
            guard s.generation == generation else { return false }
            s.link = link
            return true
        }
        if installed {
            link.add(to: runLoop, forMode: .common)
        } else {
            link.invalidate()
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let onFire = state.withLock { $0.onFire }
        _ = onFire?(HostClock.nowNanos())
    }
}
