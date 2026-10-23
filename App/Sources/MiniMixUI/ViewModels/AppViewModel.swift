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
    public internal(set) var project: Project
    public private(set) var transition: TransitionState = .idle
    /// Entrada seleccionada en la rejilla (paneles de playlist y propiedades).
    public var selectedInputID: InputID?
    public internal(set) var playback: [InputID: PlaybackInfo] = [:]
    public internal(set) var mediaDurations: [String: Double]
    /// Tiempo de la interfaz (segundos); se actualiza en `refresh`.
    public private(set) var now: Double
    public var errorMessage: String?
    public internal(set) var projectURL: URL?
    public internal(set) var programOutputDisplay: DisplayInfo.ID?

    public let mixer: MixerViewModel
    public let playlists: PlaylistViewModel
    public let status: StatusViewModel

    @ObservationIgnored let services: AppServices
    @ObservationIgnored var switcher: any SwitcherStateMachine
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var transitionInputs: (from: InputID?, to: InputID?)?
    @ObservationIgnored private var lastStatusRefresh = -Double.infinity

    public init(services: AppServices) {
        self.services = services
        let project = services.initialProject
        self.project = project
        self.switcher = services.makeSwitcher(project)
        self.mediaDurations = services.mediaDurations
        self.now = services.uptime()
        self.mixer = MixerViewModel()
        self.playlists = PlaylistViewModel(makeSequencer: services.makeSequencer)
        self.status = StatusViewModel(renderStats: services.renderStats)
        mixer.app = self
        playlists.app = self
        playlists.reset(for: project)
        selectedInputID = project.preview
    }

    public var monitorFactory: MonitorFactory { services.monitor }

    // MARK: Ciclo de vida

    /// Arranca reloj, suscripciones y alta de entradas. Idempotente.
    public func start() {
        guard tasks.isEmpty else { return }
        services.clock.start()
        let ticks = services.clock.ticks
        let meters = services.audio.meters
        let displays = services.output.displayChanges
        tasks.append(Task { [weak self] in
            for await time in ticks { self?.tick(at: time) }
        })
        tasks.append(Task { [weak self] in
            for await levels in meters { self?.mixer.receive(levels) }
        })
        tasks.append(Task { [weak self] in
            for await _ in displays { self?.programOutputDisplay = self?.services.output.activeDisplay }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        })
        Task { await registerAllInputs() }
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        services.clock.stop()
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

    private func apply(_ effects: [Effect]) {
        for effect in effects { handle(effect) }
        transition = switcher.transition
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
        case .transitionCompleted:
            transitionInputs = nil
            updateVisibility()
        case .forward(let command):
            dispatch(command)
        }
    }

    private func updateVisibility() {
        let ids = [project.preview, project.program, transitionInputs?.from, transitionInputs?.to].compactMap { $0 }
        services.inputs.setVisible(Set(ids))
    }

    // MARK: Consultas

    public func descriptor(_ id: InputID) -> InputDescriptor? {
        project.inputs.first { $0.id == id }
    }

    public func number(of id: InputID) -> Int? {
        project.inputs.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    public func isPlaying(_ id: InputID) -> Bool { playback[id]?.state == .playing }

    public var selectedInput: InputDescriptor? { selectedInputID.flatMap(descriptor) }

    /// Duración del fundido (0,1…5 s); se guarda en el proyecto.
    public var fadeDuration: Double {
        get { project.defaultFadeDuration }
        set { project.defaultFadeDuration = min(max(newValue, 0.1), 5) }
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
