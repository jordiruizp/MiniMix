// Core/Switcher/SwitcherState.swift — máquina de estados PVW/PGM (T11).
//
// Reglas (cubiertas por SwitcherStateTests):
// - Tras cada transición (cut, fade o T-bar completada) se intercambian PVW↔PGM.
// - Durante una transición `preview`/`program` conservan sus valores (saliente = program,
//   entrante = preview) hasta que se completa.
// - `selectPreview` durante una transición se ignora (la entrante queda bloqueada).
//   Si el id ya es el de Preview tampoco produce efectos.
// - `cut` sin Preview o con Preview == Programa no hace nada. `cut` durante una transición
//   la completa inmediatamente.
// - `fade` sin Preview o con Preview == Programa no hace nada. La duración se limita a
//   0,1…5 s; una duración no finita se ignora. `fade` durante un fade se ignora; durante una
//   T-bar manual toma el control y completa desde el progreso actual en el tiempo restante
//   proporcional (`duración × (1 − progreso)`).
// - `tbar(x)`: x se limita a 0…1 (no finito → se ignora). En reposo, x > 0 inicia una
//   transición manual (x ≥ 1 la completa al instante). En manual, x ≥ 1 completa y x ≤ 0
//   cancela (progress 0 + completed, sin cambio de buses). Durante un fade temporizado se ignora.
//   Si la T-bar movió la transición (aunque la complete un cut o un fade), al completarse se
//   ignoran valores > 0 hasta recibir tbar(0) (rearme), para que la palanca física, que queda
//   arriba o a medias, no dispare otra transición. La UI debería devolver la palanca a 0.
// - Efectos: inicio → [transitionStarted, transitionProgress(p0)]; avance → [transitionProgress(p)];
//   fin → [transitionProgress(1), transitionCompleted, busesChanged]. Progreso lineal.
// - Transporte/audio/playlist se devuelven como `.forward(cmd)`.

import Foundation

public struct SwitcherState: SwitcherStateMachine {
    public private(set) var preview: InputID?
    public private(set) var program: InputID?
    public var transition: TransitionState {
        guard let active else { return .idle }
        return .running(kind: active.kind, progress: active.progress)
    }

    /// `true` si una T-bar completada espera volver a 0 antes de aceptar otra transición.
    public private(set) var tbarNeedsRearm = false

    private enum Driver: Hashable, Sendable {
        /// Fade temporizado: de `startProgress` a 1 entre `start` y `start + duration`.
        case timed(start: HostTime, duration: Double, startProgress: Double)
        case manual
    }

    private struct Active: Hashable, Sendable {
        var kind: TransitionKind
        var driver: Driver
        var progress: Double
        /// La T-bar ha movido esta transición: al completarse hay que rearmarla.
        var usedTBar: Bool
    }

    private var active: Active?

    public init(preview: InputID? = nil, program: InputID? = nil) {
        self.preview = preview
        self.program = program
    }

    /// Estado inicial desde un proyecto guardado.
    public init(project: Project) {
        self.init(preview: project.preview, program: project.program)
    }

    /// Duraciones válidas de `Command.fade`.
    public static let fadeDurationRange = ModelLimits.switcherFade

    private var canTransition: Bool { preview != nil && preview != program }

    // MARK: - SwitcherStateMachine

    public mutating func apply(_ cmd: Command, at time: HostTime) -> [Effect] {
        switch cmd {
        case .selectPreview(let id): selectPreview(id)
        case .cut: cut()
        case .fade(let duration): fade(duration: duration, at: time)
        case .tbar(let position): tbar(position)
        default: [.forward(cmd)]
        }
    }

    public mutating func tick(at time: HostTime) -> [Effect] {
        guard var current = active, case let .timed(start, duration, startProgress) = current.driver else { return [] }
        let elapsed = max(0, time - start)
        let progress = min(1, startProgress + (1 - startProgress) * elapsed / duration)
        if progress >= 1 { return complete() }
        current.progress = progress
        active = current
        return [.transitionProgress(progress)]
    }

    // MARK: - Comandos

    private mutating func selectPreview(_ id: InputID) -> [Effect] {
        guard active == nil, preview != id else { return [] }
        preview = id
        return [.busesChanged(preview: preview, program: program)]
    }

    private mutating func cut() -> [Effect] {
        if active != nil { return complete() }
        guard canTransition else { return [] }
        swap(&preview, &program)
        return [.busesChanged(preview: preview, program: program)]
    }

    private mutating func fade(duration: Double, at time: HostTime) -> [Effect] {
        guard duration.isFinite else { return [] }
        let duration = clamped(duration, to: Self.fadeDurationRange)
        switch active?.driver {
        case .timed:
            return []
        case .manual:
            let progress = active?.progress ?? 0
            active?.driver = .timed(start: time, duration: duration * (1 - progress), startProgress: progress)
            return []
        case nil:
            guard canTransition else { return [] }
            return start(.timed(start: time, duration: duration, startProgress: 0), progress: 0, duration: duration)
        }
    }

    private mutating func tbar(_ position: Double) -> [Effect] {
        guard position.isFinite else { return [] }
        let position = clamped(position, to: 0...1)
        if tbarNeedsRearm {
            if position <= 0 { tbarNeedsRearm = false }
            return []
        }
        switch active?.driver {
        case .timed:
            return []
        case .manual:
            if position >= 1 { return complete() }
            if position <= 0 { return cancel() }
            active?.progress = position
            return [.transitionProgress(position)]
        case nil:
            guard position > 0, canTransition else { return [] }
            let started = start(.manual, progress: position, duration: nil)
            return position >= 1 ? started.dropLast() + complete() : started
        }
    }

    // MARK: - Ciclo de vida de la transición

    private mutating func start(_ driver: Driver, progress: Double, duration: Double?) -> [Effect] {
        active = Active(kind: .fade, driver: driver, progress: progress, usedTBar: driver == .manual)
        return [.transitionStarted(kind: .fade, from: program, to: preview, duration: duration),
                .transitionProgress(progress)]
    }

    private mutating func complete() -> [Effect] {
        if active?.usedTBar == true { tbarNeedsRearm = true }
        active = nil
        swap(&preview, &program)
        return [.transitionProgress(1), .transitionCompleted, .busesChanged(preview: preview, program: program)]
    }

    private mutating func cancel() -> [Effect] {
        active = nil
        return [.transitionProgress(0), .transitionCompleted]
    }
}
