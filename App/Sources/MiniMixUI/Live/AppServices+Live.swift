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

    /// Arranca el audio y el bucle de render (el reloj lo arranca `AppViewModel.start()`).
    public func start() {
        guard renderTask == nil else { return }
        do { try audio.start() } catch { LiveLog.app.error("AudioEngine no arrancó: \(error)") }
        let renderer = self.renderer
        let ticks = clock.ticks
        renderTask = Task.detached(priority: .userInitiated) { await renderer.run(ticks: ticks) }
    }

    public func stop() {
        renderTask?.cancel()
        renderTask = nil
        audio.stop()
    }
}

public enum LiveSetupError: Error {
    case noMetalDevice
}

extension AppServices {
    /// Servicios reales (T80): Core + Render + Media + Audio + Output + Persistence.
    public static func live(project: Project = Project()) throws -> (AppServices, LiveRuntime) {
        guard let context = MetalContext.shared else { throw LiveSetupError.noMetalDevice }
        let canvas = project.canvas.size
        let clock = MasterClock(frameRate: project.canvas.frameRate)
        let audio = try AudioEngine()
        let store = ProjectStore()
        let manager = InputManager(context: context, canvasSize: canvas, urlResolver: store.urlResolver)
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
        services.busStateSink = { renderer.update($0) }
        return (services, runtime)
    }
}
