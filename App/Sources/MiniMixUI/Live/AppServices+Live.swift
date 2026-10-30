import Audio
import Core
import Foundation
import Media
import os
import Output
import Persistence
import Render

enum LiveLog {
    static let app = Logger(subsystem: "com.ebrecode.minimix", category: "live")
}

/// Motor real de la app (T80): mantiene vivos los servicios y el bucle de render.
@MainActor
public final class LiveRuntime {
    public let context: MetalContext
    public let clock: MasterClock
    public let audio: AudioEngine
    public let inputs: LiveInputs
    public let store: ProjectStore
    public let output: OutputController
    public let renderer: LiveRenderer
    private var renderTask: Task<Void, Never>?

    init(context: MetalContext, clock: MasterClock, audio: AudioEngine, inputs: LiveInputs,
         store: ProjectStore, output: OutputController, renderer: LiveRenderer) {
        self.context = context
        self.clock = clock
        self.audio = audio
        self.inputs = inputs
        self.store = store
        self.output = output
        self.renderer = renderer
    }

    /// Arranca el audio y el bucle de render (el reloj lo arranca `AppViewModel.start()` justo
    /// después). Idempotente. Cada arranque se suscribe a un stream de ticks nuevo (contracts-v2:
    /// cada acceso a `ticks` es una suscripción), así que stop + start no congela el render.
    /// Devuelve los errores para la UI (el audio que no arranca no impide el vídeo).
    @discardableResult
    public func start() -> [String] {
        guard renderTask == nil else { return [] }
        var errors: [String] = []
        do {
            try audio.start()
        } catch {
            LiveLog.app.error("AudioEngine no arrancó: \(error)")
            errors.append("El audio no arrancó: \(error.localizedDescription)")
        }
        let renderer = self.renderer
        let ticks = clock.ticks
        renderTask = Task.detached(priority: .userInitiated) { await renderer.run(ticks: ticks) }
        return errors
    }

    public var isRunning: Bool { renderTask != nil }

    public func stop() {
        renderTask?.cancel()
        renderTask = nil
        audio.stop()
    }

    /// Proyecto con otro formato: frecuencia del reloj y lienzo/compositores del render.
    /// Los feeds no cambian (monitores y salida siguen enlazados). Las imágenes fijas se siguen
    /// decodificando al lienzo con el que se creó `InputManager` (se escalan en el compositor).
    public func reconfigure(_ canvas: CanvasFormat) {
        let format = canvas.normalized()
        clock.setFrameRate(format.frameRate)
        do {
            try renderer.reconfigure(canvas: format.size, frameRate: format.frameRate)
        } catch {
            LiveLog.app.error("No se pudo reconfigurar el render: \(error)")
            inputs.report("No se pudo cambiar el lienzo a \(format.size.width)×\(format.size.height): \(error)")
        }
    }
}

public enum LiveSetupError: Error {
    case noMetalDevice
}

extension AppServices {
    /// Servicios reales (T80): Core + Render + Media + Audio + Output + Persistence.
    /// - Parameter playlistFactory: fuente de las entradas `.playlist` (`PlaylistInput` de D, Ola 2).
    ///   Mientras sea nil, la UI desactiva «Añadir playlist». Cuando llegue: manda el secuenciador
    ///   de `PlaylistInput`; la UI refleja `SourceEvent.itemChanged` y envía playlistNext/Previous/Jump.
    public static func live(project: Project = Project(),
                            playlistFactory: InputManager.PlaylistFactory? = nil) throws -> (AppServices, LiveRuntime) {
        guard let context = MetalContext.shared else { throw LiveSetupError.noMetalDevice }
        let canvas = project.canvas.size
        let clock = MasterClock(frameRate: project.canvas.frameRate)
        let audio = try AudioEngine()
        let store = ProjectStore()
        let manager = InputManager(context: context, canvasSize: canvas, urlResolver: store.urlResolver,
                                   playlistFactory: playlistFactory)
        let inputs = LiveInputs(inputs: manager, audio: audio)
        let renderer = try LiveRenderer(context: context, canvas: canvas, frameRate: project.canvas.frameRate) {
            manager.frameSource(for: $0)
        }
        let output = OutputController(feed: renderer.programFeed, context: context)
        let runtime = LiveRuntime(context: context, clock: clock, audio: audio, inputs: inputs,
                                  store: store, output: output, renderer: renderer)
        var services = AppServices(
            initialProject: project,
            makeSwitcher: { SwitcherState(project: $0) },
            makeSequencer: { PlaylistSequencer(playlist: $0) },
            clock: clock,
            audio: audio,
            inputs: inputs,
            store: store,
            output: output,
            monitor: .render(context: context, preview: renderer.previewFeed, program: renderer.programFeed),
            renderStats: { renderer.stats })
        services.busStateSink = { renderer.update($0, refreshSources: $1) }
        services.startRuntime = { runtime.start() }
        services.stopRuntime = { runtime.stop() }
        services.reconfigureCanvas = { runtime.reconfigure($0) }
        services.serviceErrors = inputs.errors
        services.writeProject = { try store.write($0, to: $1) }
        services.activateProject = { store.activate($0) }
        services.relinkProject = { reference, url, project, folder in
            let result = try store.relinkReporting(reference, to: url, in: project, searchingIn: folder)
            return RelinkOutcome(project: result.project, relinkedPaths: result.relinkedPaths,
                                 stillUnresolved: result.stillUnresolved)
        }
        services.supportsPlaylists = playlistFactory != nil
        services.setLatencyCompensation = { audio.setLatencyCompensation(milliseconds: $0) }
        services.setEfficiencyMode = { renderer.efficiencyMode = $0 }
        services.decoderUsage = {
            DecoderUsage(active: manager.activeDecoderIDs.count, limit: manager.maxActiveVideoDecoders)
        }
        return (services, runtime)
    }
}
