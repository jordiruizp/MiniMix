import Foundation
import Media
import TestSupport

/// Lo que el bucle entrega para construir el informe.
struct LiveReportInputs {
    var startedAt: Date
    var setupStart: ContinuousClock.Instant
    var setupSeconds: Double
    var loop: LoopCounters
    var clockSkipped: Int
    var samples: [LiveReport.Sample]
    var memoryStart: Double
    var thermalStart: ThermalLevel
    var playlistStats: PlaylistInput.Stats?
    var cuts: Int
    var fades: Int
}

extension LiveScenarioRunner {
    // swiftlint:disable:next function_body_length
    func makeReport(_ inputs: LiveReportInputs) -> LiveReport {
        let probe = renderer.probe.withLock { $0 }
        let samples = inputs.samples
        let loop = inputs.loop
        let wall = loop.firstArrival.map { $0.duration(to: loop.endArrival ?? .now).seconds } ?? 0
        // Duración despierto: si el Mac se duerme (tapa cerrada en batería) el reloj de host se detiene.
        let duration = loop.firstAwake.map { $0.duration(to: loop.endAwake ?? .now).seconds } ?? wall
        let expected = Int((config.durationSeconds / config.canvas.frameRate.frameDuration).rounded())
        let loopDropped = loop.droppedByClock + loop.droppedByBackpressure
        let compositorDropped = renderer.program.stats.droppedFrames
        let firstFrame = probe.firstCodedFrameAt.map { inputs.setupStart.duration(to: $0).seconds }
        let launch = ProcessLaunch.startDate().flatMap { start in
            firstFrame.map { inputs.startedAt.timeIntervalSince(start) + $0 }
        }
        let thermalSeconds = samples.reduce(into: [String: Double]()) {
            $0[$1.thermal.rawValue, default: 0] += config.sampleIntervalSeconds
        }
        let analysis = probe.analysis
        let report = LiveReport(
            scenario: config, startedAt: inputs.startedAt, durationSeconds: duration,
            sleptSeconds: max(0, wall - duration),
            ciRunnerActiveSeconds: Double(samples.filter(\.ciRunnerActive).count) * config.sampleIntervalSeconds,
            machine: MachineInfo.current(),
            gpu: rig.context.device.name, inputs: rig.inputs,
            audio: rig.audio.map { "AudioEngine en marcha (\($0.attachedInputs.count) canales)" }
                ?? "sin AudioEngine: \(rig.audioError ?? "?")",
            coldStart: .init(setupSeconds: inputs.setupSeconds, firstProgramFrameSeconds: firstFrame,
                             processLaunchToFirstFrameSeconds: launch),
            frames: .init(targetFPS: config.canvas.frameRate.fps,
                          measuredFPS: duration > 0 ? Double(probe.completed) / duration : 0,
                          expected: expected, rendered: probe.completed, droppedByClock: loop.droppedByClock,
                          clockSkippedTicks: inputs.clockSkipped, droppedByBackpressure: loop.droppedByBackpressure,
                          compositorDropped: compositorDropped, dropped: max(loopDropped, compositorDropped),
                          droppedDuringWarmup: warmupDropped(samples),
                          maxDroppedIn30Minutes: Self.maxInWindow(samples.filter { $0.t > config.warmupSeconds },
                                                                  baseline: warmupDropped(samples), seconds: 1800),
                          outOfOrderCompletions: probe.outOfOrder,
                          droppedWhileSystemBusy: dropAttribution(samples).busy,
                          droppedWhileSystemQuiet: dropAttribution(samples).quiet),
            deliveryIntervalMs: loop.delivery.stats, cpuFrameTimeMs: loop.cpuFrame.stats,
            gpuFrameTimeMs: probe.gpuMs.stats,
            usage: Self.usage(samples), memory: memory(samples, start: inputs.memoryStart),
            thermal: .init(start: inputs.thermalStart, end: ProcessMetrics.thermalState,
                           worst: (samples.map(\.thermal) + [inputs.thermalStart]).max() ?? inputs.thermalStart,
                           secondsByState: thermalSeconds,
                           firstAboveFairAt: samples.first { $0.thermal > .fair }?.t),
            cuts: .init(cuts: inputs.cuts, fades: inputs.fades, latencyFrames: .init(probe.cutLatencyFrames),
                        latencyMs: .init(probe.cutLatencyMs), measured: probe.cutLatencyFrames.count,
                        lateCuts: probe.lateCuts,
                        unmatched: probe.unmatchedCuts),
            program: .init(analyzedFrames: analysis.total, transitionFramesExcluded: probe.transitionFrames,
                           black: analysis.black, unreadable: analysis.unreadable, filler: analysis.filler,
                           repeats: analysis.repeats, longestRun: analysis.longestRun,
                           skippedFrames: analysis.skippedFrames, boundarySkips: analysis.boundarySkips,
                           backwardJumps: analysis.backwardJumps, loopWraps: analysis.loopWraps,
                           clipChanges: analysis.clipChanges.count, foreignClipFrames: probe.foreignClipFrames),
            playlist: inputs.playlistStats.map {
                .init(items: rig.playlistItemCount, switches: $0.switches, lateSwitches: $0.lateSwitches,
                      maxLoadedItems: $0.maxLoadedItems, createdItems: $0.createdItems,
                      lastStartLatencyMs: $0.lastStartLatency.map { $0 * 1000 })
            },
            skipsByClip: [:], skipEvents: [],
            maxActiveDecoders: samples.map(\.activeDecoders).max() ?? 0,
            avOffset: "no medido en T90 (informativo según el encargo; requiere capturar la salida de audio "
                + "y casar el pitido con el parche de la claqueta)",
            targets: [], samples: samples)
        var withTargets = report
        withTargets.skipsByClip = Dictionary(uniqueKeysWithValues: probe.skipsByClip.map { ("\($0.key)", $0.value) })
        withTargets.skipEvents = probe.skipEvents
        withTargets.targets = Self.targets(report)
        return withTargets
    }

    /// Perdidos acumulados al terminar el calentamiento (arranque de decodificadores).
    private func warmupDropped(_ samples: [LiveReport.Sample]) -> Int {
        samples.last { $0.t <= config.warmupSeconds }?.droppedFrames ?? 0
    }

    /// Reparte los perdidos tras el calentamiento según la CPU del sistema en cada intervalo.
    private func dropAttribution(_ samples: [LiveReport.Sample]) -> (busy: Int, quiet: Int) {
        var busy = 0
        var quiet = 0
        for (previous, sample) in zip(samples, samples.dropFirst()) where sample.t > config.warmupSeconds {
            let delta = sample.droppedFrames - previous.droppedFrames
            if (sample.systemCPUPercent ?? 0) >= 70 { busy += delta } else { quiet += delta }
        }
        return (busy, quiet)
    }

    /// Máximo de perdidos en cualquier ventana de `seconds` (contadores acumulados de las muestras).
    private static func maxInWindow(_ samples: [LiveReport.Sample], baseline: Int, seconds: Double) -> Int {
        var best = 0
        var startIndex = 0
        for sample in samples {
            while samples[startIndex].t < sample.t - seconds { startIndex += 1 }
            let base = startIndex > 0 ? samples[startIndex - 1].droppedFrames : baseline
            best = max(best, sample.droppedFrames - base)
        }
        return best
    }

    private static func usage(_ samples: [LiveReport.Sample]) -> LiveReport.Usage {
        func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        let cpu = samples.map(\.cpuPercent)
        let system = samples.compactMap(\.systemCPUPercent)
        let gpuSystem = samples.compactMap(\.gpuSystemPercent)
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        return .init(processCPUMeanPercent: mean(cpu), processCPUPeakPercent: cpu.max() ?? 0,
                     processCPUMeanOfMachinePercent: mean(cpu) / cores,
                     systemCPUMeanPercent: system.isEmpty ? nil : mean(system),
                     gpuFrameMeanPercent: mean(samples.map(\.gpuFramePercent)),
                     gpuFramePeakPercent: samples.map(\.gpuFramePercent).max() ?? 0,
                     gpuSystemMeanPercent: gpuSystem.isEmpty ? nil : mean(gpuSystem),
                     gpuSystemPeakPercent: gpuSystem.max())
    }

    private func memory(_ samples: [LiveReport.Sample], start: Double) -> LiveReport.Memory {
        let steady = samples.filter { $0.t >= config.warmupSeconds }
        let hours = 1.0 / 3600
        return .init(startMB: start, peakMB: samples.map(\.footprintMB).max() ?? start,
                     endMB: samples.last?.footprintMB ?? start, residentPeakMB: samples.map(\.residentMB).max() ?? 0,
                     footprintDriftMBPerHour: Regression.slope(steady.map { ($0.t * hours, $0.footprintMB) }),
                     residentDriftMBPerHour: Regression.slope(steady.map { ($0.t * hours, $0.residentMB) }))
    }

    /// Objetivos de la sección 10.2 del plan.
    static func targets(_ report: LiveReport) -> [LiveReport.Target] {
        let f = report.frames
        let longEnough = report.durationSeconds >= 1800
        let slept = (report.sleptSeconds > 1
            ? String(format: " — ⚠ el Mac durmió %.0f s durante la ejecución", report.sleptSeconds) : "")
            + (report.ciRunnerActiveSeconds > 0
               ? String(format: " — ⚠ CI activo %.0f s", report.ciRunnerActiveSeconds) : "")
        let latency = report.cuts
        func fmt(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }
        let list: [LiveReport.Target] = [
            .init(name: "Fotogramas perdidos (tras el calentamiento)", target: "0 en 30 min",
                  measured: "\(f.maxDroppedIn30Minutes) (máx. en 30 min); total \(f.dropped) de \(f.expected), "
                    + "\(f.droppedDuringWarmup) en el arranque; \(f.droppedWhileSystemQuiet) con la máquina tranquila / "
                    + "\(f.droppedWhileSystemBusy) con CPU del sistema ≥ 70 %" + (longEnough ? "" : " — ejecución < 30 min") + slept,
                  pass: f.maxDroppedIn30Minutes == 0),
            .init(name: "RAM (phys_footprint pico)", target: "< 1,5 GB",
                  measured: "\(fmt(report.memory.peakMB, 0)) MB; deriva \(fmt(report.memory.footprintDriftMBPerHour)) MB/h",
                  pass: report.memory.peakMB < 1536),
            .init(name: "CPU media (proceso, 100 % = 1 núcleo)", target: "< 30 %",
                  measured: "\(fmt(report.usage.processCPUMeanPercent)) % (máquina: "
                    + "\(report.usage.systemCPUMeanPercent.map { fmt($0) } ?? "n/d") %)",
                  pass: report.usage.processCPUMeanPercent < 30),
            .init(name: "GPU media (tiempo de nuestros fotogramas)", target: "< 50 %",
                  measured: "\(fmt(report.usage.gpuFrameMeanPercent)) % (sistema: "
                    + "\(report.usage.gpuSystemMeanPercent.map { fmt($0) } ?? "n/d") %)",
                  pass: report.usage.gpuFrameMeanPercent < 50),
            .init(name: "Latencia de Cut", target: "≤ 1 fotograma",
                  measured: latency.measured == 0 ? "sin cortes medidos"
                    : "máx. \(fmt(latency.latencyFrames.max, 0)) fot. (p50 \(fmt(latency.latencyFrames.p50, 0))), "
                    + "\(fmt(latency.latencyMs.p50)) ms p50 hasta GPU; sin casar \(latency.unmatched)",
                  pass: latency.measured == 0 ? nil : latency.latencyFrames.max <= 1 && latency.unmatched == 0),
            .init(name: "Desfase A/V", target: "< 20 ms", measured: report.avOffset, pass: nil),
            .init(name: "Térmica", target: "≤ .fair tras 1 h",
                  measured: "final \(report.thermal.end.rawValue), peor \(report.thermal.worst.rawValue)",
                  pass: report.thermal.end <= .fair && report.thermal.worst <= .fair),
            .init(name: "Arranque en frío (8 entradas → 1.er fotograma)", target: "< 2 s",
                  measured: report.coldStart.firstProgramFrameSeconds.map { "\(fmt($0, 2)) s" } ?? "sin fotograma",
                  pass: report.coldStart.firstProgramFrameSeconds.map { $0 < 2 })
        ]
        // CPU, GPU y térmica dependen de que el Mac esté despierto y libre de CI.
        return list.map { target in
            var target = target
            if ["CPU", "GPU", "Térmica"].contains(where: { target.name.hasPrefix($0) }) { target.measured += slept }
            return target
        }
    }
}
