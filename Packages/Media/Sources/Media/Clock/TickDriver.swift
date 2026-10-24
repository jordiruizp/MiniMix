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

// MARK: - Vsync con vigilancia

/// Fuente de pulsos de vsync (el `CADisplayLink` real o una falsa en tests).
protocol VSyncSource: AnyObject, Sendable {
    func start(_ onStep: @escaping @Sendable () -> Void)
    func stop()
    /// Duración de un refresco de la pantalla (ns).
    var frameNanos: Int64 { get }
}

/// Driver ligado a la pantalla con vigilancia: si el vsync deja de llegar durante
/// más de 3 refrescos (ventana oculta, pantalla dormida o desconectada, sin
/// pantalla), cae al `TimerTickDriver`; vuelve al vsync en cuanto llega un pulso o
/// al recibir `NSApplication.didChangeScreenParametersNotification` (que reinstala
/// el enlace, p. ej. tras conectar otra pantalla).
final class VSyncTickDriver: TickDriver {
    private struct State {
        var onFire: (@Sendable (Int64) -> Int64)?
        var lastStepNanos: Int64 = 0
        var usingFallback = false
        var watchdog: DispatchSourceTimer?
        var observer: NSObjectProtocol?
        var fallbackStarts = 0
    }

    private let vsync: any VSyncSource
    private let fallback: any TickDriver
    private let initialGraceNanos: Int64
    private let queue = DispatchQueue(label: "minimix.clock.watchdog", qos: .userInteractive)
    private let state = LockedState(State())

    init(vsync: any VSyncSource, fallback: any TickDriver = TimerTickDriver(), initialGraceNanos: Int64 = 250_000_000) {
        self.vsync = vsync
        self.fallback = fallback
        self.initialGraceNanos = initialGraceNanos
    }

    var firesOffGrid: Bool { true }
    var isUsingFallback: Bool { state.withLock { $0.usingFallback } }
    /// Veces que se ha caído al temporizador (diagnóstico).
    var fallbackStarts: Int { state.withLock { $0.fallbackStarts } }

    private var stallNanos: Int64 { 3 * max(vsync.frameNanos, 1_000_000) }

    func start(_ onFire: @escaping @Sendable (Int64) -> Int64) {
        stop()
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
            self?.screenParametersChanged()
        }
        state.withLock { s in
            s.onFire = onFire
            s.usingFallback = false
            s.lastStepNanos = HostClock.nowNanos() + initialGraceNanos
            s.watchdog = watchdog
            s.observer = observer
        }
        watchdog.setEventHandler { [weak self] in self?.checkStall() }
        let interval = DispatchTimeInterval.nanoseconds(Int(max(stallNanos / 2, 5_000_000)))
        watchdog.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        watchdog.activate()
        vsync.start { [weak self] in self?.step() }
    }

    func stop() {
        let (watchdog, observer) = state.withLock { s -> (DispatchSourceTimer?, NSObjectProtocol?) in
            defer {
                s.onFire = nil
                s.watchdog = nil
                s.observer = nil
                s.usingFallback = false
            }
            return (s.watchdog, s.observer)
        }
        watchdog?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        vsync.stop()
        fallback.stop()
    }

    private func step() {
        let now = HostClock.nowNanos()
        let (onFire, wasFallback) = state.withLock { s -> ((@Sendable (Int64) -> Int64)?, Bool) in
            defer {
                s.lastStepNanos = now
                s.usingFallback = false
            }
            return (s.onFire, s.usingFallback)
        }
        if wasFallback { fallback.stop() }
        _ = onFire?(now)
    }

    private func checkStall() {
        let now = HostClock.nowNanos()
        let stall = stallNanos
        let onFire = state.withLock { s -> (@Sendable (Int64) -> Int64)? in
            guard let onFire = s.onFire, !s.usingFallback, now - s.lastStepNanos > stall else { return nil }
            s.usingFallback = true
            s.fallbackStarts += 1
            return onFire
        }
        if let onFire { fallback.start(onFire) }
    }

    private func screenParametersChanged() {
        let reinstall = state.withLock { s -> Bool in
            guard s.onFire != nil, s.usingFallback else { return false }
            s.lastStepNanos = HostClock.nowNanos() + initialGraceNanos
            return true
        }
        guard reinstall else { return }
        vsync.stop()
        vsync.start { [weak self] in self?.step() }
    }
}

/// `CADisplayLink` de macOS 14+ (`NSScreen.displayLink`) servido en un hilo propio
/// (no en el principal, que es de la interfaz). Sin pantalla no emite pulsos y la
/// vigilancia de `VSyncTickDriver` cae al temporizador.
///
/// `@unchecked Sendable` justificado: `CADisplayLink`, `RunLoop` y `Thread` no son
/// `Sendable`. El enlace se crea en el main actor (exigencia de AppKit), se
/// registra en el run loop del hilo propio (uso documentado de
/// `add(to:forMode:)`) y después solo se toca bajo `state`.
final class DisplayLinkVSync: NSObject, VSyncSource, @unchecked Sendable {
    private struct State {
        var link: CADisplayLink?
        var onStep: (@Sendable () -> Void)?
        var thread: Thread?
        var generation = 0
        var frameNanos: Int64 = 16_666_667
    }

    private let state = LockedState(State())

    var frameNanos: Int64 { state.withLock { $0.frameNanos } }

    /// true si hay al menos una pantalla activa (consulta segura fuera del main actor).
    static var hasDisplay: Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }

    func start(_ onStep: @escaping @Sendable () -> Void) {
        stop()
        let generation = state.withLock { s -> Int in
            s.onStep = onStep
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
                s.onStep = nil
                s.generation += 1
            }
            return (s.link, s.thread)
        }
        link?.invalidate()
        thread?.cancel()
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
        let refresh = link.targetTimestamp - link.timestamp
        let onStep = state.withLock { s -> (@Sendable () -> Void)? in
            if refresh > 0.001, refresh < 0.1 { s.frameNanos = Int64(refresh * 1e9) }
            return s.onStep
        }
        onStep?()
    }
}
