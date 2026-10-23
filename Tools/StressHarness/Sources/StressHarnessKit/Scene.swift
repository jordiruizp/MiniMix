import Core
import Foundation
import Metal
import TestSupport

/// Estado de un escenario durante la ejecución: entradas, switcher y playlist.
struct Scene {
    private let config: ScenarioConfig
    private let factory: PipelineFactory
    private var switcher: any SwitcherStateMachine
    private var sources: [InputID: FrameSource] = [:]
    private var order: [InputID] = []
    private var lastAction = 0.0
    private var playlist: PlaylistState?
    private(set) var events = StressReport.Events()

    static func make(config: ScenarioConfig, factory: PipelineFactory) async throws -> Scene {
        var scene = Scene(config: config, factory: factory, switcher: factory.makeSwitcher())
        for index in 0..<max(config.inputs, 2) {
            let id = InputID()
            let hue = Double(index) / Double(max(config.inputs, 2))
            let source = factory.makeSource(id: id, content: .color(RGBAColor(red: hue, green: 1 - hue, blue: 0.5)),
                                            canvas: config.canvas.size)
            try await source.prepare()
            source.play()
            scene.sources[id] = source
            scene.order.append(id)
        }
        if case .playlist(let items, let itemSeconds, let loop) = config.kind {
            let state = PlaylistState(items: items, itemSeconds: itemSeconds, loop: loop, factory: factory,
                                      canvas: config.canvas.size)
            scene.playlist = state
            // La playlist sustituye a la primera entrada como Programa.
            scene.order[0] = state.inputID
        }
        _ = scene.switcher.apply(.selectPreview(scene.order[0]), at: .zero)
        _ = scene.switcher.apply(.cut, at: .zero)
        _ = scene.switcher.apply(.selectPreview(scene.order[1]), at: .zero)
        if let playlist = scene.playlist {
            scene.events.playlistItemsStarted = playlist.start()
            // Como al pulsar play en la app tras cargar: la medida empieza con el primer item listo.
            await playlist.waitUntilLoaded(timeout: .seconds(5))
        }
        return scene
    }

    private init(config: ScenarioConfig, factory: PipelineFactory, switcher: any SwitcherStateMachine) {
        self.config = config
        self.factory = factory
        self.switcher = switcher
    }

    /// Avanza un fotograma y devuelve lo que hay que componer.
    mutating func advance(to time: HostTime, elapsed: Double) -> CompositorFrame {
        if case .switchEvery(let seconds, let transition, let fadeSeconds) = config.kind,
           elapsed - lastAction >= seconds {
            lastAction = elapsed
            let command: Command = transition == .fade ? .fade(duration: fadeSeconds) : .cut
            record(switcher.apply(command, at: time))
            events.switches += 1
        }
        record(switcher.tick(at: time))
        if let playlist {
            let changes = playlist.advance(elapsed: elapsed)
            events.playlistItemsStarted += changes.started
            events.playlistLoops += changes.loops
            events.maxLoadedPlaylistItems = max(events.maxLoadedPlaylistItems, playlist.maxLoaded)
        }

        let programTexture = texture(for: switcher.program, at: time)
        switch switcher.transition {
        case .idle:
            return CompositorFrame(a: programTexture, b: nil, mix: 0, kind: .cut)
        case .running(let kind, let progress):
            return CompositorFrame(a: programTexture, b: texture(for: switcher.preview, at: time),
                                   mix: Float(TransitionCurve.videoMix(progress)), kind: kind)
        }
    }

    private mutating func texture(for id: InputID?, at time: HostTime) -> MTLTexture? {
        guard let id else { return nil }
        if let playlist, id == playlist.inputID {
            let texture = playlist.texture(at: time)
            if texture == nil { events.playlistNotReadyFrames += 1 }
            return texture
        }
        return sources[id]?.texture(for: time)
    }

    /// Tras completar una transición/corte, pone en Preview la siguiente entrada (rotación).
    private mutating func record(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .transitionCompleted:
                events.transitionsCompleted += 1
            case .busesChanged where switcher.transition == .idle:
                rotatePreview()
            default:
                break
            }
        }
    }

    private mutating func rotatePreview() {
        guard let program = switcher.program, let index = order.firstIndex(of: program) else { return }
        let next = order[(index + 1) % order.count]
        if next != switcher.preview { _ = switcher.apply(.selectPreview(next), at: .zero) }
    }

    func tearDown() {
        for source in sources.values { source.pause() }
        playlist?.tearDown()
    }
}

/// Playlist simulada: secuenciador del pipeline + carga A/B (máx. 2 items cargados).
final class PlaylistState {
    struct Changes {
        var started = 0
        var loops = 0
    }

    private struct Loaded {
        var sources: [Int: FrameSource] = [:]
        var pending: Set<Int> = []
        var maxLoaded = 0
    }

    let inputID = InputID()
    private var sequencer: any PlaylistSequencing
    private let itemSeconds: Double
    private let factory: PipelineFactory
    private let canvas: PixelSize
    private let loaded = LockedBox(Loaded())
    private var itemStart = 0.0

    init(items: Int, itemSeconds: Double, loop: Bool, factory: PipelineFactory, canvas: PixelSize) {
        let media = TestMediaLocator.root.path
        let list = (0..<items).map { index -> PlaylistItem in
            switch index % 3 {
            case 0: PlaylistItem(source: .video(MediaReference(path: "\(media)/playlist_mixed/01_h264_1080p25.mp4")),
                                 duration: itemSeconds)
            case 1: PlaylistItem(source: .image(MediaReference(path: "\(media)/playlist_mixed/02_image_1920x1080.png")),
                                 duration: itemSeconds)
            default: PlaylistItem(source: .color(RGBAColor(red: 0.125, green: 0.25, blue: 0.75)), duration: itemSeconds)
            }
        }
        sequencer = factory.makeSequencer(Playlist(items: list, loop: loop))
        self.itemSeconds = itemSeconds
        self.factory = factory
        self.canvas = canvas
    }

    var maxLoaded: Int { loaded.withLock { $0.maxLoaded } }

    /// Arranca la playlist; devuelve los items iniciados (0 o 1).
    func start() -> Int {
        guard case .playing = sequencer.handle(.play) else { return 0 }
        ensureLoaded()
        return 1
    }

    func advance(elapsed: Double) -> Changes {
        var changes = Changes()
        guard elapsed - itemStart >= itemSeconds, case .playing(let before) = sequencer.state else { return changes }
        itemStart = elapsed
        var state = sequencer.handle(.itemEnded)
        if state == .ended { state = sequencer.handle(.play) }
        if case .playing(let after) = state {
            changes.started = 1
            if after <= before { changes.loops = 1 }
        }
        ensureLoaded()
        return changes
    }

    /// Espera a que no quede ninguna carga pendiente.
    func waitUntilLoaded(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while loaded.withLock({ !$0.pending.isEmpty }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func texture(at time: HostTime) -> MTLTexture? {
        guard case .playing(let index) = sequencer.state else { return nil }
        return loaded.withLock { $0.sources[index] }?.texture(for: time)
    }

    /// Mantiene cargados solo el item actual y el siguiente; prepara los que falten en segundo plano.
    private func ensureLoaded() {
        var wanted: [Int] = []
        if case .playing(let index) = sequencer.state { wanted.append(index) }
        if let upcoming = sequencer.upcomingIndex, !wanted.contains(upcoming) { wanted.append(upcoming) }
        let items = sequencer.playlist.items
        let toLoad: [Int] = loaded.withLock { state in
            state.sources = state.sources.filter { wanted.contains($0.key) }
            state.pending = state.pending.filter { wanted.contains($0) }
            let missing = wanted.filter { state.sources[$0] == nil && !state.pending.contains($0) }
            state.pending.formUnion(missing)
            state.maxLoaded = max(state.maxLoaded, state.sources.count + state.pending.count)
            return missing
        }
        for index in toLoad {
            let content = Self.content(of: items[index].source)
            let source = factory.makeSource(id: InputID(), content: content, canvas: canvas)
            let loaded = loaded
            Task.detached(priority: .userInitiated) {
                try? await source.prepare()
                source.play()
                loaded.withLock {
                    // Si mientras tanto dejó de hacer falta, se descarta.
                    if $0.pending.remove(index) != nil { $0.sources[index] = source }
                }
            }
        }
    }

    private static func content(of source: ItemSource) -> InputContent {
        switch source {
        case .video(let ref): .video(ref)
        case .audio(let ref): .audio(ref, visual: .black)
        case .image(let ref): .image(ref)
        case .color(let color): .color(color)
        }
    }

    func tearDown() { loaded.withLock { $0.sources.removeAll() } }
}
