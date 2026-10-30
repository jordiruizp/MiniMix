import Core
import Foundation
import Observation

/// Reloj de reproducción visto por la interfaz (para tiempos restantes).
public struct PlaybackInfo: Hashable, Sendable {
    public var state: PlaybackState = .idle
    var startedAt: Double?
    var accumulated: Double = 0

    public func elapsed(at now: Double) -> Double {
        accumulated + (startedAt.map { max(0, now - $0) } ?? 0)
    }

    mutating func play(at now: Double) {
        if startedAt == nil { startedAt = now }
        state = .playing
    }

    mutating func pause(at now: Double) {
        accumulated = elapsed(at: now)
        startedAt = nil
        state = .paused
    }

    mutating func reset(at now: Double, playing: Bool) {
        accumulated = 0
        startedAt = playing ? now : nil
    }

    mutating func end(at now: Double) {
        pause(at: now)
        state = .ended
    }
}

/// ViewModel raíz. Todo cambio de buses, transporte y audio pasa por `send(_:)`:
/// el switcher (`SwitcherStateMachine`) produce `Effect`s y aquí se despachan a los servicios.
@MainActor @Observable
public final class AppViewModel {
    public internal(set) var project: Project {
        didSet {
            // Cambios sin guardar (T91): solo el contenido de documento (los buses no cuentan).
            // Se compara una vez por mutación, no en cada evaluación de las vistas.
            guard !isDirty, !suppressDirtyTracking,
                  Self.documentContent(oldValue) != Self.documentContent(project) else { return }
            isDirty = true
        }
    }
    /// Hay cambios desde el último guardado/apertura/proyecto nuevo.
    public internal(set) var isDirty = false
    @ObservationIgnored var suppressDirtyTracking = false
    public private(set) var transition: TransitionState = .idle
    /// Entrada seleccionada en la rejilla (paneles de playlist y propiedades).
    public var selectedInputID: InputID?
    public internal(set) var playback: [InputID: PlaybackInfo] = [:]
    public internal(set) var mediaDurations: [String: Double]
    /// Tiempo de la interfaz (segundos); se actualiza en `refresh`.
    public private(set) var now: Double
    public var errorMessage: String?
    public internal(set) var projectURL: URL?
    /// Archivos del proyecto abierto que no se encontraron (diálogo de reenlace).
    public internal(set) var missingReferences: [MediaReference] = []
    public internal(set) var programOutputDisplay: DisplayInfo.ID?
    /// Posición física de la palanca de la T-bar (0…1). Vuelve a 0 al completarse la transición
    /// (y se envía `.tbar(0)` para rearmar `SwitcherState`).
    public private(set) var tbarPosition: Double = 0
    /// La palanca está agarrada (arrastre en curso): el rearme espera a `releaseTBar()`.
    public private(set) var isDraggingTBar = false
    /// Una transición se completó con la palanca agarrada (p. ej. un fundido automático): se
    /// ignoran sus valores hasta `releaseTBar()` para que no arranque otra transición.
    @ObservationIgnored private var tbarLockedUntilRelease = false

    /// Preferencias (escena Settings); se guardan y se aplican al cambiar.
    public var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save(to: services.defaults)
            applyPreferences(changedFrom: oldValue)
        }
    }

    public let mixer: MixerViewModel
    public let playlists: PlaylistViewModel
    public let status: StatusViewModel

    @ObservationIgnored let services: AppServices
    @ObservationIgnored var switcher: any SwitcherStateMachine
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Altas/bajas pendientes en el gestor de entradas (se cancelan en `stop` y al abrir proyecto).
    /// Cada tarea se quita sola al terminar (no crece sin límite en sesiones largas).
    @ObservationIgnored var pendingTasks: [UUID: Task<Void, Never>] = [:]
    /// Última edición en directo por entrada (para encadenar `update`s).
    @ObservationIgnored var liveEditChains: [InputID: Task<Void, Never>] = [:]
    @ObservationIgnored private var persistentTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var inputsRegistered = false
    /// Suscripción a `FrameSource.events` por entrada (identidad de la fuente + tarea).
    @ObservationIgnored var sourceSubscriptions: [InputID: (source: ObjectIdentifier, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var transitionInputs: (from: InputID?, to: InputID?)?
    @ObservationIgnored private var lastStatusRefresh = -Double.infinity
    /// Último `BusState` entregado al render (para no republicar uno idéntico).
    @ObservationIgnored var lastPublishedBus: BusState?

    public init(services: AppServices) {
        self.services = services
        let project = services.initialProject
        self.project = project
        self.preferences = Preferences.load(from: services.defaults)
        self.switcher = services.makeSwitcher(project)
        self.mediaDurations = services.mediaDurations
        self.now = services.uptime()
        self.mixer = MixerViewModel()
        self.playlists = PlaylistViewModel(makeSequencer: services.makeSequencer)
        self.status = StatusViewModel(renderStats: services.renderStats, decoderUsage: services.decoderUsage)
        mixer.app = self
        playlists.app = self
        playlists.reset(for: project)
        selectedInputID = project.preview
    }

    public var monitorFactory: MonitorFactory { services.monitor }

    // MARK: Ciclo de vida

    /// Arranca motor real (si lo hay), reloj, suscripciones y, la primera vez, el alta de entradas.
    /// Idempotente; tras `stop()` se puede volver a llamar.
    public func start() {
        guard tasks.isEmpty else { return }
        startPersistentSubscriptions()
        for message in services.startRuntime?() ?? [] { errorMessage = message }
        services.clock.start()
        // contracts-v2: cada acceso a `ticks` es una suscripción nueva (se recrea en cada arranque).
        let ticks = services.clock.ticks
        tasks.append(Task { [weak self] in
            for await time in ticks { self?.tick(at: time) }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        })
        if let demo = services.demoStart { tasks.append(demo()) }
        if !inputsRegistered {
            inputsRegistered = true
            applyPreferences(changedFrom: nil)
            track { await $0.registerAllInputs() }
            restoreProgramOutput()
        }
    }

    /// Para el reloj, el motor real y las tareas de esta ejecución. Las entradas siguen dadas de
    /// alta y las suscripciones de un solo consumidor (vúmetros, pantallas, errores) siguen vivas:
    /// cancelarlas terminaría sus streams para siempre.
    public func stop() {
        (tasks + Array(pendingTasks.values)).forEach { $0.cancel() }
        tasks.removeAll()
        pendingTasks.removeAll()
        services.clock.stop()
        services.stopRuntime?()
    }

    public var isRunning: Bool { !tasks.isEmpty }

    /// `meters`, `displayChanges` y `serviceErrors` son de un solo consumidor: se leen una vez
    /// durante toda la vida del ViewModel.
    private func startPersistentSubscriptions() {
        guard persistentTasks.isEmpty else { return }
        let meters = services.audio.meters
        let displays = services.output.displayChanges
        persistentTasks.append(Task { [weak self] in
            for await levels in meters { self?.mixer.receive(levels) }
        })
        persistentTasks.append(Task { [weak self] in
            for await _ in displays { self?.outputDisplaysChanged() }
        })
        if let errors = services.serviceErrors {
            persistentTasks.append(Task { [weak self] in
                for await message in errors { self?.errorMessage = message }
            })
        }
    }

    /// Refresco de la interfaz (~4 Hz): tiempos, simulación de mocks y barra de estado.
    public func refresh(now: Double? = nil) {
        self.now = now ?? services.uptime()
        if services.simulatesPlayback { simulatePlaybackEnds() }
        services.demoTick?(self)
        if self.now - lastStatusRefresh >= 1 {
            lastStatusRefresh = self.now
            status.refresh()
        }
    }

    // MARK: Comandos

    /// Punto único de entrada de comandos (UI, atajos y en el futuro MIDI/Stream Deck).
    public func send(_ command: Command) {
        apply(switcher.apply(command, at: services.clock.now))
    }

    func tick(at time: HostTime) {
        apply(switcher.tick(at: time))
    }

    /// Mueve la palanca de la T-bar (arrastre) a una posición absoluta y la envía al switcher.
    /// Si la transición se completa durante el arrastre, `SwitcherState` ignora el resto de
    /// valores hasta el rearme, que se hace al soltar.
    public func moveTBar(to position: Double) {
        guard position.isFinite else { return }
        isDraggingTBar = true
        guard !tbarLockedUntilRelease else { return }
        tbarPosition = min(max(position, 0), 1)
        send(.tbar(tbarPosition))
    }

    /// Al soltar la palanca: si no hay transición en curso (completada o ignorada), vuelve a 0.
    /// Si queda una transición manual a medias, la palanca se queda donde está.
    public func releaseTBar() {
        isDraggingTBar = false
        tbarLockedUntilRelease = false
        if transitionProgress == nil, tbarPosition > 0 { rearmTBar() }
    }

    func apply(_ effects: [Effect]) {
        var completed = false
        for effect in effects {
            if effect == .transitionCompleted || effect == .transitionCancelled { completed = true }
            handle(effect)
        }
        transition = switcher.transition
        publishBusState()
        if completed, isDraggingTBar { tbarLockedUntilRelease = true }
        if completed, tbarPosition > 0, !isDraggingTBar { rearmTBar() }
    }

    /// Devuelve la palanca a 0; `SwitcherState` ignora la T-bar hasta recibir `.tbar(0)`.
    private func rearmTBar() {
        tbarPosition = 0
        apply(switcher.apply(.tbar(0), at: services.clock.now))
    }

    /// Lanza una tarea de alta/baja de entradas y la guarda para poder cancelarla.
    @discardableResult
    func track(_ body: @escaping @MainActor @Sendable (AppViewModel) async -> Void) -> Task<Void, Never> {
        let key = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await body(self)
            pendingTasks[key] = nil
        }
        pendingTasks[key] = task
        return task
    }

    private func handle(_ effect: Effect) {
        switch effect {
        case let .busesChanged(preview, program):
            let oldProgram = project.program
            project.preview = preview
            project.program = program
            if oldProgram != program, transitionInputs == nil {
                services.audio.transition(from: oldProgram, to: program, progress: 1)
            }
            updateVisibility()
        case let .transitionStarted(_, from, to, _):
            transitionInputs = (from, to)
            updateVisibility()
        case .transitionProgress(let progress):
            services.audio.transition(from: transitionInputs?.from, to: transitionInputs?.to, progress: progress)
        case .transitionCompleted, .transitionCancelled:
            transitionInputs = nil
            updateVisibility()
        case .forward(let command):
            dispatch(command)
        }
    }

    /// Tras abrir un proyecto: sin transición en curso y con la palanca en reposo.
    func resetTransitionState() {
        transitionInputs = nil
        transition = switcher.transition
        tbarPosition = 0
        isDraggingTBar = false
        tbarLockedUntilRelease = false
    }

    func updateVisibility() {
        let ids = [project.preview, project.program, transitionInputs?.from, transitionInputs?.to].compactMap { $0 }
        services.inputs.setVisible(Set(ids))
    }

    // MARK: Consultas

    public func descriptor(_ id: InputID) -> InputDescriptor? { project.input(withID: id) }

    public func number(of id: InputID) -> Int? { project.index(ofInput: id).map { $0 + 1 } }

    public func isPlaying(_ id: InputID) -> Bool { playback[id]?.state == .playing }

    public var selectedInput: InputDescriptor? { selectedInputID.flatMap(descriptor) }

    /// Duración del fundido (0,1…5 s); se guarda en el proyecto.
    public var fadeDuration: Double {
        get { project.defaultFadeDuration }
        set {
            let range = ModelLimits.switcherFade
            project.defaultFadeDuration = min(max(newValue, range.lowerBound), range.upperBound)
        }
    }

    /// Progreso de la transición en curso (0…1), o nil.
    public var transitionProgress: Double? {
        if case .running(_, let progress) = transition { return progress }
        return nil
    }

    /// Selecciona una entrada en la rejilla y la pone en Preview.
    public func selectInput(_ id: InputID) {
        selectedInputID = id
        send(.selectPreview(id))
    }

    /// Duración útil (con recortes) de una entrada de vídeo/audio, si se conoce.
    public func duration(of input: InputDescriptor) -> Double? {
        guard input.kind == .video || input.kind == .audio,
              let path = input.content.mediaReference?.path else { return nil }
        let full = mediaDurations[path]
        guard let end = input.outPoint ?? full else { return nil }
        return max(0, end - (input.inPoint ?? 0))
    }

    /// Tiempo restante de una entrada (vídeo/audio: clip; playlist: playlist entera).
    public func remaining(for id: InputID) -> Double? {
        guard let input = descriptor(id) else { return nil }
        if input.kind == .playlist { return playlists.playlistRemaining(for: id) }
        // Con fuente real: fin útil (Out o duración del archivo) menos la posición actual.
        if let position = sourcePosition(id),
           let end = input.outPoint ?? input.content.mediaReference.flatMap({ mediaDurations[$0.path] }) {
            return max(0, end - position)
        }
        guard let total = duration(of: input) else { return nil }
        return max(0, total - (playback[id]?.elapsed(at: now) ?? 0))
    }

    /// Registra una duración conocida (en T80, desde `SourceEvent.durationKnown`).
    public func setMediaDuration(_ seconds: Double, forPath path: String) {
        mediaDurations[path] = seconds
    }

    // MARK: Simulación (fase de mocks)

    private func simulatePlaybackEnds() {
        for (id, info) in playback where info.state == .playing {
            guard let input = descriptor(id) else { continue }
            if input.kind == .playlist {
                playlists.simulateItemEnd(for: id)
            } else if let left = remaining(for: id), left <= 0 {
                if input.loop {
                    playback[id]?.reset(at: now, playing: true)
                } else {
                    playback[id]?.end(at: now)
                }
            }
        }
    }
}
