import AppKit
import CoreGraphics
import Darwin
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
    /// Duración de un fotograma del proyecto (ns), para drivers que la usan en su
    /// planificación (temporizador de tiempo real). Se llama al arrancar y en
    /// `setFrameRate`.
    func setFramePeriod(nanos: Int64)
}

extension TickDriver {
    func setFramePeriod(nanos: Int64) {}
}

/// Temporizador de alta precisión: un hilo propio con política de **tiempo real**
/// (`THREAD_TIME_CONSTRAINT_POLICY`, como los hilos de audio y de vídeo del sistema)
/// que duerme con `mach_wait_until` hasta el instante exacto que pide la rejilla.
///
/// Sustituye al `DispatchSourceTimer` (cola `userInteractive`): en reposo, ese hilo
/// sufría esperas ocasionales de hasta ~130 ms (planificación/coalescencia de
/// temporizadores) que saltaban fotogramas de la rejilla (10 en 30 min). Un hilo con
/// restricción de tiempo lo planifica el núcleo por delante del resto.
final class TimerTickDriver: TickDriver {
    /// Generación actual: el hilo de una generación anterior termina en ≤ `maxSleepNanos`.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    /// Tope de cada espera: `stop()` surte efecto sin esperar al siguiente fotograma.
    private static let maxSleepNanos: Int64 = 50_000_000
    /// Periodo de la política de tiempo real (un fotograma del proyecto); el hilo la
    /// vuelve a aplicar cuando cambia.
    private let period = OSAllocatedUnfairLock<Int64>(initialState: 16_666_667)
    private static let logger = Logger(subsystem: "MiniMix", category: "MasterClock")

    var periodNanosForTesting: Int64 { period.withLock { $0 } }

    func setFramePeriod(nanos: Int64) {
        period.withLock { $0 = max(nanos, 1_000_000) }
    }

    var firesOffGrid: Bool { false }

    func start(_ onFire: @escaping @Sendable (Int64) -> Int64) {
        let mine = generation.withLock { g -> Int in
            g += 1
            return g
        }
        let generation = self.generation
        let period = self.period
        let thread = Thread {
            var applied: Int64 = 0
            var next = HostClock.nowNanos()
            while generation.withLock({ $0 }) == mine {
                let wanted = period.withLock { $0 }
                if wanted != applied {
                    Self.becomeRealtime(periodNanos: wanted)
                    applied = wanted
                }
                let now = HostClock.nowNanos()
                if now < next {
                    mach_wait_until(Self.machTicks(nanos: min(next, now + Self.maxSleepNanos)))
                    continue
                }
                next = onFire(HostClock.nowNanos())
            }
        }
        thread.name = "minimix.clock.timer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        generation.withLock { $0 += 1 }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// ns del host → unidades de `mach_absolute_time`.
    static func machTicks(nanos: Int64) -> UInt64 {
        UInt64(max(0, Double(nanos) * Double(timebase.denom) / Double(timebase.numer)))
    }

    /// Política de tiempo real para el hilo actual: periodo de un fotograma, cómputo y
    /// plazo de pocos ms (el trabajo de cada tick es mínimo: calcular el índice y avisar).
    private static func becomeRealtime(periodNanos: Int64) {
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(machTicks(nanos: periodNanos)),
            computation: UInt32(machTicks(nanos: 1_000_000)),
            constraint: UInt32(machTicks(nanos: 2_000_000)),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        if status != KERN_SUCCESS {
            logger.error("thread_policy_set(TIME_CONSTRAINT) falló: \(status, privacy: .public); el reloj sigue sin tiempo real")
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
/// pantalla), cae al `TimerTickDriver`.
///
/// Histéresis: para volver al vsync hacen falta `recoveryPulses` pulsos seguidos,
/// cada uno a menos de 3 refrescos del anterior; un pulso suelto tras un corte no
/// basta. Así un vsync irregular (máquina cargada) no hace oscilar entre fuentes.
/// `NSApplication.didChangeScreenParametersNotification` reinstala el enlace (p. ej.
/// tras conectar otra pantalla). Mientras manda el temporizador, los pulsos no
/// disparan ticks (el reloj descartaría duplicados de todos modos).
final class VSyncTickDriver: TickDriver {
    private struct State {
        var onFire: (@Sendable (Int64) -> Int64)?
        var lastStepNanos: Int64 = 0
        var usingFallback = false
        var recoveryCount = 0
        var watchdog: DispatchSourceTimer?
        var observer: NSObjectProtocol?
        var fallbackStarts = 0
    }

    private let vsync: any VSyncSource
    private let fallback: any TickDriver
    private let initialGraceNanos: Int64
    private let recoveryPulses: Int
    private let watchdogInterval: DispatchTimeInterval?
    private let now: @Sendable () -> Int64
    private let queue = DispatchQueue(label: "minimix.clock.watchdog", qos: .userInteractive)
    private let state = LockedState(State())
    /// Centro de notificaciones de los cambios de pantalla (inyectable: los tests usan uno
    /// propio para que el aviso de un test no llegue a los drivers de otros en paralelo).
    /// En `LockedState` porque `NotificationCenter` no está anotado como `Sendable` en todos los SDK.
    private let notifications: LockedState<NotificationCenter>

    /// - Parameters:
    ///   - watchdogInterval: cada cuánto se vigila; nil = sin temporizador (los tests
    ///     llaman a `checkStall()`). Por defecto, medio umbral de corte.
    ///   - now: reloj en ns del host (inyectable en tests).
    init(vsync: any VSyncSource, fallback: any TickDriver = TimerTickDriver(),
         initialGraceNanos: Int64 = 250_000_000, recoveryPulses: Int = 3,
         watchdogInterval: DispatchTimeInterval? = .milliseconds(25),
         now: @escaping @Sendable () -> Int64 = HostClock.nowNanos,
         notificationCenter: NotificationCenter = .default) {
        notifications = LockedState(notificationCenter)
        self.vsync = vsync
        self.fallback = fallback
        self.initialGraceNanos = initialGraceNanos
        self.recoveryPulses = max(1, recoveryPulses)
        self.watchdogInterval = watchdogInterval
        self.now = now
    }

    var firesOffGrid: Bool { true }
    var isUsingFallback: Bool { state.withLock { $0.usingFallback } }
    /// Veces que se ha caído al temporizador (diagnóstico).
    var fallbackStarts: Int { state.withLock { $0.fallbackStarts } }

    private var stallNanos: Int64 { 3 * max(vsync.frameNanos, 1_000_000) }

    func start(_ onFire: @escaping @Sendable (Int64) -> Int64) {
        stop()
        let observer = notifications.current.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
            self?.screenParametersChanged()
        }
        var watchdog: DispatchSourceTimer?
        if let interval = watchdogInterval {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.checkStall() }
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
            watchdog = timer
        }
        let start = now()
        state.withLock { s in
            s.onFire = onFire
            s.usingFallback = false
            s.recoveryCount = 0
            s.lastStepNanos = start + initialGraceNanos
            s.watchdog = watchdog
            s.observer = observer
        }
        watchdog?.activate()
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
        if let observer { notifications.current.removeObserver(observer) }
        vsync.stop()
        fallback.stop()
    }

    /// Pulso de vsync.
    func step() {
        let time = now()
        let stall = stallNanos
        let required = recoveryPulses
        let (onFire, recovered) = state.withLock { s -> ((@Sendable (Int64) -> Int64)?, Bool) in
            defer { s.lastStepNanos = time }
            guard s.usingFallback else { return (s.onFire, false) }
            s.recoveryCount = time - s.lastStepNanos <= stall ? s.recoveryCount + 1 : 1
            guard s.recoveryCount >= required else { return (nil, false) }
            s.usingFallback = false
            s.recoveryCount = 0
            return (s.onFire, true)
        }
        if recovered { fallback.stop() }
        _ = onFire?(time)
    }

    /// Vigilancia: cae al temporizador si el último pulso es de hace más de 3 refrescos.
    func checkStall() {
        let time = now()
        let stall = stallNanos
        let onFire = state.withLock { s -> (@Sendable (Int64) -> Int64)? in
            guard let onFire = s.onFire, !s.usingFallback, time - s.lastStepNanos > stall else { return nil }
            s.usingFallback = true
            s.recoveryCount = 0
            s.fallbackStarts += 1
            return onFire
        }
        if let onFire { fallback.start(onFire) }
    }

    private func screenParametersChanged() {
        let time = now()
        let reinstall = state.withLock { s -> Bool in
            guard s.onFire != nil, s.usingFallback else { return false }
            s.recoveryCount = 0
            s.lastStepNanos = time
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
    /// Desde que `.automatic` usa el temporizador, solo lo usan los tests para omitir
    /// las pruebas de `.displayLink` en máquinas sin pantalla.
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
