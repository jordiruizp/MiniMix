import Core
import CoreMocks
import Foundation
import Render
import SwiftUI

/// Bus de vídeo que muestra un monitor.
public enum MonitorBus: String, Sendable {
    case preview, program
}

/// Qué pinta un monitor. Hoy `MonitorPlaceholder`; en T80 el `MonitorView` (MTKView) de Render.
public struct MonitorContent {
    public var bus: MonitorBus
    /// Entrada asignada al bus (nil = negro).
    public var input: InputDescriptor?
    /// Entrada entrante durante una transición (solo Programa).
    public var incoming: InputDescriptor?
    /// Mezcla 0…1 ya pasada por `TransitionCurve.videoMix`.
    public var mix: Double
}

/// Fábrica de monitores: único punto que hay que cambiar para usar Render.
@MainActor
public struct MonitorFactory {
    public var make: @MainActor (MonitorContent) -> AnyView
    public init(make: @escaping @MainActor (MonitorContent) -> AnyView) { self.make = make }

    public static let placeholder = MonitorFactory { AnyView(MonitorPlaceholder(content: $0)) }

    /// Monitores Metal de Render. Cada bus pinta lo que se publique en su `MonitorFeed`
    /// (lo alimenta `LiveRenderer`, T80). Es el que usa `AppServices.live()`.
    public static func render(context: MetalContext, preview: MonitorFeed, program: MonitorFeed) -> MonitorFactory {
        MonitorFactory { content in
            let isPreview = content.bus == .preview
            return AnyView(MonitorView(feed: isPreview ? preview : program, context: context,
                                       borderColor: isPreview ? RGBAColor(red: 0, green: 0.8, blue: 0.3)
                                                              : RGBAColor(red: 0.9, green: 0.1, blue: 0.1)))
        }
    }
}

/// Resultado de un reenlace (espejo de `Persistence.RelinkResult`, que no tiene init público).
public struct RelinkOutcome: Sendable, Equatable {
    public var project: Project
    public var relinkedPaths: [String]
    public var stillUnresolved: [MediaReference]

    public init(project: Project, relinkedPaths: [String], stillUnresolved: [MediaReference]) {
        self.project = project
        self.relinkedPaths = relinkedPaths
        self.stillUnresolved = stillUnresolved
    }
}

/// Dependencias de la interfaz. Todo se habla a través de los protocolos del contrato.
/// `AppServices.mocks()` es la configuración con CoreMocks; T80 crea `AppServices.live(...)`.
@MainActor
public struct AppServices {
    public var initialProject: Project
    public var makeSwitcher: @MainActor (Project) -> any SwitcherStateMachine
    public var makeSequencer: @MainActor (Playlist) -> any PlaylistSequencing
    public var clock: any MasterClockProtocol
    public var audio: any AudioMixing
    public var inputs: any InputManaging
    public var store: any ProjectStoring
    public var output: any OutputPresenting
    public var monitor: MonitorFactory
    /// Estadísticas del render para la barra de estado (Render expone `RenderStats`).
    public var renderStats: @MainActor () -> RenderStats
    /// Tiempo de la interfaz en segundos (tiempos restantes). Inyectable en tests.
    public var uptime: @MainActor () -> Double
    /// Duraciones conocidas por ruta (en T80 llegan de `SourceEvent.durationKnown`).
    public var mediaDurations: [String: Double]
    /// Fase de mocks: la UI simula el fin de items y clips porque no hay fuentes reales.
    public var simulatesPlayback: Bool
    /// Gancho de demostración llamado en cada refresco (vúmetros falsos). nil en producción.
    public var demoTick: (@MainActor (AppViewModel) -> Void)?
    /// Demo: tarea lanzada en `start()` (p. ej. hace avanzar `MockClock` a 60 Hz). nil en producción.
    public var demoStart: (@MainActor () -> Task<Void, Never>)?
    /// T80: recibe los buses/transición/encajes cuando cambian (lo consume el render).
    /// `sourcesChanged`: alguna fuente se dio de alta, se sustituyó o se quitó (el render debe
    /// volver a resolver sus `FrameSource`).
    public var busStateSink: (@MainActor (_ state: BusState, _ sourcesChanged: Bool) -> Void)?

    // MARK: Integración real (G-real). nil/valores neutros en mocks.

    /// Arranca el motor real (audio + bucle de render) antes que el reloj. Devuelve los errores
    /// que la UI debe mostrar (p. ej. el audio no arrancó).
    public var startRuntime: (@MainActor () -> [String])?
    /// Para el motor real (render y audio). Lo llama `AppViewModel.stop()`.
    public var stopRuntime: (@MainActor () -> Void)?
    /// Proyecto con otro lienzo/frecuencia: reloj y render se reconfiguran antes de dar de alta las entradas.
    public var reconfigureCanvas: (@MainActor (CanvasFormat) -> Void)?
    /// Errores asíncronos de los servicios (p. ej. conectar el audio de una entrada). Un solo consumidor.
    public var serviceErrors: AsyncStream<String>?
    /// `ProjectStore.write(_:to:)`: guarda y devuelve el proyecto con bookmarks, que la App adopta.
    /// nil → `store.save`.
    public var writeProject: (@MainActor (Project, URL) throws -> Project)?
    /// `ProjectStore.activate(_:)`: tras sustituir las entradas, abre el acceso a los archivos del proyecto.
    public var activateProject: (@MainActor (Project) -> Void)?
    /// `ProjectStore.relinkReporting(_:to:in:searchingIn:)` (diálogo de reenlace).
    public var relinkProject: (@MainActor (MediaReference, URL, Project, URL?) throws -> RelinkOutcome)?
    /// El gestor de entradas sabe crear fuentes de playlist (`InputManager(playlistFactory:)`).
    public var supportsPlaylists = true
    /// Preferencias (pantalla de salida elegida). Inyectable en tests.
    public var defaults: UserDefaults = .standard

    public init(
        initialProject: Project,
        makeSwitcher: @escaping @MainActor (Project) -> any SwitcherStateMachine,
        makeSequencer: @escaping @MainActor (Playlist) -> any PlaylistSequencing,
        clock: any MasterClockProtocol,
        audio: any AudioMixing,
        inputs: any InputManaging,
        store: any ProjectStoring,
        output: any OutputPresenting,
        monitor: MonitorFactory = .placeholder,
        renderStats: @escaping @MainActor () -> RenderStats,
        uptime: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        mediaDurations: [String: Double] = [:],
        simulatesPlayback: Bool = false,
        demoTick: (@MainActor (AppViewModel) -> Void)? = nil,
        demoStart: (@MainActor () -> Task<Void, Never>)? = nil
    ) {
        self.initialProject = initialProject
        self.makeSwitcher = makeSwitcher
        self.makeSequencer = makeSequencer
        self.clock = clock
        self.audio = audio
        self.inputs = inputs
        self.store = store
        self.output = output
        self.monitor = monitor
        self.renderStats = renderStats
        self.uptime = uptime
        self.mediaDurations = mediaDurations
        self.simulatesPlayback = simulatesPlayback
        self.demoTick = demoTick
        self.demoStart = demoStart
    }
}

extension AppServices {
    /// Configuración de la fase de mocks: `SwitcherState` y `PlaylistSequencer` reales de Core;
    /// reloj, audio, entradas, persistencia y salida de CoreMocks; datos de `SampleData.project`.
    public static func mocks(
        project: Project = SampleData.project,
        audio: MockAudioMixer = MockAudioMixer(),
        demo: Bool = true
    ) -> AppServices {
        let makeSwitcher: @MainActor (Project) -> any SwitcherStateMachine = {
            SwitcherState(project: $0)
        }
        let makeSequencer: @MainActor (Playlist) -> any PlaylistSequencing = { PlaylistSequencer(playlist: $0) }
        var demoTick: (@MainActor (AppViewModel) -> Void)?
        var demoStart: (@MainActor () -> Task<Void, Never>)?
        let clock = MockClock()
        if demo {
            demoTick = { DemoMeters.emit(into: audio, for: $0) }
            // MockClock no avanza solo: sin esto los fundidos de SwitcherState no progresarían.
            demoStart = {
                Task {
                    while !Task.isCancelled {
                        clock.advance()
                        try? await Task.sleep(for: .seconds(clock.frameRate.frameDuration))
                    }
                }
            }
        }
        return AppServices(
            initialProject: project,
            makeSwitcher: makeSwitcher,
            makeSequencer: makeSequencer,
            clock: clock,
            audio: audio,
            inputs: MockInputManager(),
            store: MockProjectStore(),
            output: MockOutputPresenter(),
            renderStats: { RenderStats(fps: 60, droppedFrames: 0, gpuTimeMs: 5.6) },
            mediaDurations: ["/tmp/clip.mov": 95, "/tmp/a.mp4": 12, "/tmp/m.wav": 184],
            simulatesPlayback: true,
            demoTick: demoTick,
            demoStart: demoStart
        )
    }
}

/// Vúmetros falsos para la demo con mocks: pasan por `AudioMixing.meters` como los reales.
enum DemoMeters {
    @MainActor
    static func emit(into mixer: MockAudioMixer, for app: AppViewModel) {
        var levels: [InputID?: [Float]] = [:]
        var master: Float = -90
        for input in app.project.inputs where input.kind.hasAudio {
            let playing = app.playback[input.id]?.state == .playing
            let gain = input.muted ? 0 : input.volume
            let base: Float = playing ? -14 : -90
            let left = base + Float.random(in: -8...4) + 20 * log10(max(gain, 0.0001))
            let right = left + Float.random(in: -2...2)
            levels[input.id] = [min(left, 0), min(right, 0)]
            if playing { master = max(master, left) }
        }
        let masterDB = min(master + 20 * log10(max(app.project.masterVolume, 0.0001)), 0)
        levels[nil] = [masterDB, masterDB]
        mixer.emit(levels)
    }
}
