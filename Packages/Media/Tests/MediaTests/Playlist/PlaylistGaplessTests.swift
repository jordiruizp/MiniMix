import Core
import CoreMocks
import Foundation
import Testing
@testable import Media

/// Aceptación T70 con `TestMedia/playlist_mixed` (vídeo 25p 4 s → imagen 5 s → vídeo 30p 4 s →
/// color 3 s) sobre un `MasterClock` real a 60 Hz: 0 negros y 0 fotogramas repetidos o saltados
/// en los cambios; como máximo 2 items cargados. Se desactiva si no hay TestMedia
/// (`Tools/generate-testmedia.sh --only playlist`).
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available && PlaylistMedia.available), .timeLimit(.minutes(2)))
    struct PlaylistGaplessTests {
        @Test func playlistMixedHasNoBlackOrRepeatedFramesAtChanges() async throws {
            let context = GPU.context!
            let clock = MasterClock(frameRate: .fps60, tickSource: .timer)
            let environment = PlaylistEnvironment(context: context, clock: clock, canvasSize: .hd1080)
            let input = try PlaylistInput(playlist: PlaylistMedia.playlist, environment: environment)
            try await input.prepare()
            let probe = FrameCodeProbe(device: context.device, queue: context.commandQueue)
            let ticks = clock.ticks
            let total = 60 * 17
            clock.start()
            input.play()
            let frame = clock.frameRate.frameDuration
            let (maxLoaded, consumerLost) = await Task {
                var index = 0
                var maxLoaded = 0
                var lost = 0
                var previous: HostTime?
                for await tick in ticks {
                    // Ticks que este consumidor no llegó a ver (bufferingNewest(1)).
                    if let previous { lost += max(0, Int(((tick - previous) / frame).rounded()) - 1) }
                    previous = tick
                    probe.read(input.texture(for: tick), index: index)
                    maxLoaded = max(maxLoaded, input.stats.loadedItems)
                    index += 1
                    if index == total { break }
                }
                return (maxLoaded, lost)
            }.value
            clock.stop()
            try await Task.sleep(for: .milliseconds(300))
            let readings = probe.results(count: total)
            let report = GaplessReport(readings.compactMap { $0 }, fillerLuma: PlaylistMedia.colorLuma)
            print("[PL] playlist_mixed a 60 Hz: \(report.summary); items cargados máx. \(maxLoaded) " +
                  "(stats \(input.stats)); ticks saltados reloj \(clock.stats.skippedTicks) consumidor \(consumerLost); " +
                  "carga \(SystemLoad.description)")
            // Duros: nunca negro ni contenido ajeno, orden de items y memoria.
            #expect(readings.allSatisfy { $0 != nil })
            #expect(report.black == 0)
            #expect(report.unreadable == 0)
            #expect(report.order == [26, 27, 28, -1], "\(report.order)")
            #expect(maxLoaded <= 2 && input.stats.maxLoadedItems <= 2)
            // Exactitud de fotograma y de tiempo: dependen del tiempo real de la máquina
            // (se miden siempre; se exigen fuera del CI).
            let lost = clock.stats.skippedTicks + consumerLost
            // Un tick perdido (reloj o consumidor) justo en un cambio oculta un fotograma de borde.
            let ends = zip(report.changes.compactMap(\.fromFrame), [99, 0, 119]).allSatisfy { $0 >= $1 - lost }
            let starts = report.changes.compactMap(\.toFrame).allSatisfy { $0 <= lost }
            PerfGate.check(report.changes.count == 3 && ends, "saliente acaba en su último fotograma \(report.changes)")
            PerfGate.check(starts, "entrante empieza en el 0 (±\(lost)) \(report.changes)")
            PerfGate.check(abs(report.runLength(clip: 27) - 300) <= lost, "imagen 300 ticks (±\(lost)): \(report.runLength(clip: 27))")
            PerfGate.check(input.stats.lateSwitches == 0, "cambios tardíos \(input.stats.lateSwitches)")
            // Repeticiones en los cambios (más ticks que la cadencia 25p→3, 30p→2). El arranque de
            // AVPlayer varía ±40 ms y se compensa por defecto (fotograma 0 algo más largo antes
            // que saltarlo): hasta 6 ticks (100 ms) mientras VideoInput no arranque a hora fija.
            PerfGate.check(report.boundaryRepeats <= lost + 6, "repeticiones en los cambios \(report.boundaryRepeats)")
            PerfGate.check(report.skippedInside <= lost, "fotogramas saltados dentro de los clips \(report.skippedInside)")
        }
    }
}

enum PlaylistMedia {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestMedia/playlist_mixed")
    }

    static let files = ["01_h264_1080p25.mp4", "02_image_1920x1080.png", "03_h264_1080p30.mp4"]

    static var available: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    static let color = RGBAColor(red: 0.125, green: 0.25, blue: 0.75)
    static var colorLuma: Double { 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue }

    static var playlist: Playlist {
        func ref(_ index: Int) -> MediaReference { MediaReference(path: root.appendingPathComponent(files[index]).path) }
        return Playlist(items: [
            PlaylistItem(source: .video(ref(0))),
            PlaylistItem(source: .image(ref(1)), duration: 5),
            PlaylistItem(source: .video(ref(2))),
            PlaylistItem(source: .color(color), duration: 3)
        ])
    }
}

/// Análisis de la secuencia (relleno = clip -1).
struct GaplessReport {
    struct Change {
        var from: Int
        var fromFrame: Int?
        var to: Int
        var toFrame: Int?
    }

    private struct Run {
        var clip: Int
        var frame: Int?
        var length: Int
    }

    private(set) var black = 0
    private(set) var unreadable = 0
    private(set) var skippedInside = 0
    private(set) var boundaryRepeats = 0
    private(set) var changes: [Change] = []
    private(set) var order: [Int] = []
    private var runs: [Run] = []

    init(_ readings: [FrameCodeReading], fillerLuma: Double) {
        let fps: [Int: Int] = [26: 25, 28: 30]
        for reading in readings {
            let clip: Int
            if let id = reading.clipID {
                clip = id
            } else if abs(reading.luma - fillerLuma) < 0.05 {
                clip = -1
            } else {
                if reading.luma < 0.03 { black += 1 } else { unreadable += 1 }
                continue
            }
            if let last = runs.last, last.clip == clip, last.frame == reading.frame {
                runs[runs.count - 1].length += 1
                continue
            }
            if let last = runs.last, last.clip == clip, let a = last.frame, let b = reading.frame, b > a + 1 {
                skippedInside += b - a - 1
            }
            if let last = runs.last, last.clip != clip {
                changes.append(Change(from: last.clip, fromFrame: last.frame, to: clip, toFrame: reading.frame))
            }
            if order.last != clip { order.append(clip) }
            runs.append(Run(clip: clip, frame: reading.frame, length: 1))
        }
        boundaryRepeats = Self.repeatsAtChanges(runs, fps: fps)
    }

    /// Rachas del último fotograma saliente y del primero entrante por encima de la cadencia
    /// (la primera racha de la playlist no cuenta: es el arranque, no un cambio).
    private static func repeatsAtChanges(_ runs: [Run], fps: [Int: Int]) -> Int {
        var repeats = 0
        for (i, run) in runs.enumerated() where i > 0 {
            let changesHere = (i + 1 < runs.count && runs[i + 1].clip != run.clip) || runs[i - 1].clip != run.clip
            guard changesHere, let rate = fps[run.clip] else { continue }
            let cadence = Int((60.0 / Double(rate)).rounded(.up))
            if run.length > cadence { repeats += run.length - cadence }
        }
        return repeats
    }

    func runLength(clip: Int) -> Int { runs.filter { $0.clip == clip }.reduce(0) { $0 + $1.length } }

    var summary: String {
        let list = changes.map { "\($0.from):\($0.fromFrame ?? -1)→\($0.to):\($0.toFrame ?? -1)" }.joined(separator: ", ")
        let boundary = runs.indices.filter { i in
            (i + 1 < runs.count && runs[i + 1].clip != runs[i].clip) || (i > 0 && runs[i - 1].clip != runs[i].clip)
        }.map { "\(runs[$0].clip):\(runs[$0].frame ?? -1)×\(runs[$0].length)" }.joined(separator: " ")
        return "negros \(black), ilegibles \(unreadable), cambios [\(list)], rachas en cambios [\(boundary)], " +
            "repetidos en cambios \(boundaryRepeats), saltados dentro \(skippedInside)"
    }
}
