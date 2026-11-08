import Core
import Foundation
import Media
import TestSupport

/// Ejecuta un escenario T90 sobre los módulos reales y produce un `LiveReport`.
///
/// Igual que la app (T80): el `MasterClock` marca el ritmo; en cada tick se aplican las acciones del
/// escenario al `SwitcherState`, los efectos se traducen a buses, visibilidad (`setVisible`: solo
/// Programa, Preview y las de la transición decodifican) y audio (`AudioEngine.transition`), y se
/// compone el fotograma (Programa + Preview) sin esperar a la GPU.
public final class LiveScenarioRunner {
    public let config: LiveScenarioConfig
    private(set) var rig: LiveRig!
    private(set) var renderer: LiveFrameRenderer!
    private var switcher = SwitcherState()
    private var transitionInputs: (from: InputID?, to: InputID?)?
    private var sources: [InputID: FrameSource] = [:]
    private var bus = HarnessBus()
    private var cuts = 0
    private var fades = 0
    private var nextIsFade = false
    private var lastAction = 0.0

    public init(config: LiveScenarioConfig) { self.config = config }

    // swiftlint:disable:next function_body_length
    public func run(progress: (@Sendable (String) -> Void)? = nil) async throws -> LiveReport {
        let startedAt = Date()
        let setupStart = ContinuousClock.now
        rig = try await LiveRig.make(canvas: config.canvas)
        let setupSeconds = setupStart.duration(to: .now).seconds
        let isPlaylist = if case .playlist = config.kind { true } else { false }
        renderer = try LiveFrameRenderer(context: rig.context, canvas: config.canvas,
                                         expectedProgramClips: isPlaylist ? rig.playlistClipIDs : nil)
        let (program, preview) = isPlaylist ? (rig.playlistID, rig.inputs[0].id) : (rig.inputs[0].id, rig.inputs[1].id)
        apply(.selectPreview(program), at: .zero)
        apply(.cut, at: .zero)
        apply(.selectPreview(preview), at: .zero)
        rig.audio?.transition(from: nil, to: program, progress: 1)

        let sampler = LiveSampler(interval: config.sampleIntervalSeconds, renderer: renderer, manager: rig.manager)
        let memoryStart = Double(ProcessMetrics.physFootprint() ?? 0) / 1_048_576
        let thermalStart = ProcessMetrics.thermalState
        let frameDuration = config.canvas.frameRate.frameDuration
        var loop = LoopCounters()
        let ticks = rig.clock.ticks
        rig.clock.start()
        sampler.start()

        for await tick in ticks {
            let arrival = ContinuousClock.now
            if let last = loop.lastArrival { loop.delivery.add(last.duration(to: arrival).seconds * 1000) }
            loop.lastArrival = arrival
            let first = loop.firstTick ?? tick
            if loop.firstTick == nil {
                loop.firstTick = tick
                loop.firstArrival = arrival
                loop.firstAwake = SuspendingClock.now
            }
            let frameIndex = Int(((tick - first) / frameDuration).rounded())
            if let lastIndex = loop.lastIndex { loop.droppedByClock += max(0, frameIndex - lastIndex - 1) }
            loop.lastIndex = frameIndex
            let elapsed = tick - first
            if elapsed + frameDuration / 2 >= config.durationSeconds {
                loop.endArrival = arrival
                loop.endAwake = SuspendingClock.now
                break
            }
            scenarioAction(at: tick, elapsed: elapsed, frameIndex: frameIndex)
            handle(switcher.tick(at: tick), at: tick)
            if renderer.render(bus: bus, sources: sources, at: tick, frameIndex: frameIndex) {
                loop.submitted += 1
            } else {
                loop.droppedByBackpressure += 1
            }
            let droppedSoFar = loop.droppedByClock + loop.droppedByBackpressure
            sampler.dropped.withLock { $0 = droppedSoFar }
            loop.cpuFrame.add(arrival.duration(to: .now).seconds * 1000)
            if elapsed - loop.lastProgress >= config.progressIntervalSeconds {
                loop.lastProgress = elapsed
                let probe = renderer.probe.withLock { ($0.completed, $0.analysis.black, $0.analysis.unreadable) }
                progress?(String(format: "  %6.0f s · %d fotogramas · perdidos reloj %d / GPU %d · negros %d · ilegibles %d · %.0f MB",
                                 elapsed, probe.0, loop.droppedByClock, loop.droppedByBackpressure, probe.1, probe.2,
                                 Double(ProcessMetrics.physFootprint() ?? 0) / 1_048_576))
            }
        }
        let clockStats = rig.clock.stats
        rig.clock.stop()
        for _ in 0..<400 where renderer.probe.withLock({ $0.inFlight }) > 0 { try await Task.sleep(for: .milliseconds(5)) }
        sampler.stop()
        let playlistStats = rig.playlist?.stats
        rig.tearDown()
        return makeReport(LiveReportInputs(
            startedAt: startedAt, setupStart: setupStart, setupSeconds: setupSeconds, loop: loop,
            clockSkipped: clockStats.skippedTicks, samples: sampler.samples, memoryStart: memoryStart,
            thermalStart: thermalStart, playlistStats: playlistStats, cuts: cuts, fades: fades))
    }

    // MARK: Escenario

    private func scenarioAction(at tick: HostTime, elapsed: Double, frameIndex: Int) {
        switch config.kind {
        case .cuts(let every, let fadeSeconds):
            guard elapsed - lastAction >= every, switcher.transition == .idle else { return }
            lastAction = elapsed
            if nextIsFade {
                fades += 1
                apply(.fade(duration: fadeSeconds), at: tick)
            } else {
                cuts += 1
                if let target = switcher.preview, let clip = rig.inputs.first(where: { $0.id == target })?.clipID {
                    renderer.expectCut(to: clip, at: frameIndex)
                }
                apply(.cut, at: tick)
            }
            nextIsFade.toggle()
        case .playlist(let previewEvery):
            guard elapsed - lastAction >= previewEvery else { return }
            lastAction = elapsed
            let videos = rig.inputs.filter { $0.isVideo && $0.id != rig.playlistID }
            if let index = videos.firstIndex(where: { $0.id == switcher.preview }) {
                apply(.selectPreview(videos[(index + 1) % videos.count].id), at: tick)
            }
        }
    }

    private func apply(_ command: Command, at time: HostTime) {
        handle(switcher.apply(command, at: time), at: time)
    }

    /// Igual que `AppViewModel.handle(_:)`: buses, audio y visibilidad.
    private func handle(_ effects: [Effect], at time: HostTime) {
        guard !effects.isEmpty else { return }
        var rotate = false
        for effect in effects {
            switch effect {
            case let .busesChanged(_, program):
                if bus.program != program, transitionInputs == nil {
                    rig.audio?.transition(from: bus.program, to: program, progress: 1)
                }
                bus.program = program
                rotate = switcher.transition == .idle && !isPlaylistScenario
            case let .transitionStarted(_, from, to, _):
                transitionInputs = (from, to)
            case .transitionProgress(let progress):
                rig.audio?.transition(from: transitionInputs?.from, to: transitionInputs?.to, progress: progress)
            case .transitionCompleted, .transitionCancelled:
                transitionInputs = nil
            case .forward:
                break
            }
        }
        if rotate, let program = switcher.program, let index = rig.inputs.firstIndex(where: { $0.id == program }) {
            let next = rig.inputs[(index + 1) % rig.inputs.count].id
            if next != switcher.preview { _ = switcher.apply(.selectPreview(next), at: time) }
        }
        publishBus()
    }

    private var isPlaylistScenario: Bool { if case .playlist = config.kind { true } else { false } }

    private func publishBus() {
        var next = HarnessBus(preview: switcher.preview, program: switcher.program)
        if case let .running(kind, progress) = switcher.transition {
            next.transition = .init(from: transitionInputs?.from ?? switcher.program,
                                    to: transitionInputs?.to ?? switcher.preview, kind: kind, progress: progress)
        }
        let ids = Set([next.preview, next.program, next.transition?.from, next.transition?.to].compactMap { $0 })
        if Set(sources.keys) != ids {
            sources = Dictionary(uniqueKeysWithValues: ids.compactMap { id in rig.manager.frameSource(for: id).map { (id, $0) } })
            rig.manager.setVisible(ids)
        }
        bus = next
    }
}

/// Contadores del bucle de render.
struct LoopCounters {
    var firstTick: HostTime?
    var firstArrival: ContinuousClock.Instant?
    var endArrival: ContinuousClock.Instant?
    /// Igual con `SuspendingClock` (no avanza con el Mac dormido): la diferencia es el tiempo dormido.
    var firstAwake: SuspendingClock.Instant?
    var endAwake: SuspendingClock.Instant?
    var lastArrival: ContinuousClock.Instant?
    var lastIndex: Int?
    var lastProgress = 0.0
    var submitted = 0
    var droppedByClock = 0
    var droppedByBackpressure = 0
    var delivery = Histogram(binWidth: 0.1, upperBound: 200)
    var cpuFrame = Histogram(binWidth: 0.01, upperBound: 50)
}
