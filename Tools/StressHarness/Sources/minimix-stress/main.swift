// minimix-stress — harness de estrés y medición (H · T61/T90).
//
// Escenarios T90 sobre los módulos reales (TestMedia generado): stress-5m-cuts, stress-5m-playlist,
// stress-1h-playlist, stress-2h-cuts (admiten --duration). Ejecuciones largas en segundo plano con
// `caffeinate -i`.
//
// Uso:
//   swift run --package-path Tools/StressHarness -c release minimix-stress \
//       [--scenario switch-every-3s|fade-every-3s|playlist-50|<archivo.json>] [--duration 30]
//       [--fps 60|59.94|50|30|25] [--size 1920x1080] [--pipeline core-render|mock]
//       [--out Tools/reports] [--list]
//
// Escribe un informe JSON por ejecución en Tools/reports/ (ignorado por git) e imprime su ruta.

import Core
import Foundation
import StressHarnessKit

let defaultReportsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("reports")

func loadScenario(_ options: StressOptions) throws -> ScenarioConfig {
    var config: ScenarioConfig
    if let builtIn = ScenarioConfig.named(options.scenario) {
        config = builtIn
    } else if FileManager.default.fileExists(atPath: options.scenario) {
        config = try JSONDecoder().decode(ScenarioConfig.self, from: Data(contentsOf: URL(fileURLWithPath: options.scenario)))
    } else {
        throw StressOptions.UsageError.usage("escenario desconocido: \(options.scenario) (--list)")
    }
    if let duration = options.duration { config.durationSeconds = duration }
    if let fps = options.fps { config.canvas.frameRate = fps }
    if let size = options.size { config.canvas.size = size }
    return config
}

func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Escenario T90 (módulos reales): imprime progreso y la tabla de objetivos 10.2.
func runLive(_ base: LiveScenarioConfig, options: StressOptions) async throws {
    var config = base
    if let duration = options.duration { config.durationSeconds = duration }
    say("▶ \(config.name) · real · \(config.durationSeconds) s · 1080p60 · 8 entradas")
    let report = try await LiveScenarioRunner(config: config).run { say($0) }
    let url = try report.write(to: options.out ?? defaultReportsDirectory)
    for target in report.targets {
        let mark = target.pass.map { $0 ? "✔" : "✘" } ?? "·"
        say("\(mark) \(target.name): objetivo \(target.target) — \(target.measured)")
    }
    say(url.path)
}

do {
    let options = try StressOptions.parse(Array(CommandLine.arguments.dropFirst()))
    if let live = LiveScenarioConfig.named(options.scenario) {
        try await runLive(live, options: options)
        exit(0)
    }
    if options.list {
        print("Escenarios T90 (reales): " + LiveScenarioConfig.builtIn.map(\.name).joined(separator: ", "))
        print("Escenarios: " + ScenarioConfig.builtIn.map(\.name).joined(separator: ", "))
        print("Pipelines: " + PipelineRegistry.factories.keys.sorted().joined(separator: ", "))
        exit(0)
    }
    let config = try loadScenario(options)
    guard let factory = PipelineRegistry.make(options.pipeline) else {
        throw StressOptions.UsageError.usage("pipeline desconocido: \(options.pipeline)")
    }
    print("▶ \(config.name) · \(factory.name) · \(config.durationSeconds) s · "
          + "\(config.canvas.size.width)x\(config.canvas.size.height)@\(config.canvas.frameRate.fps)")
    let report = try await ScenarioRunner(config: config, factory: factory).run()
    let url = try report.write(to: options.out ?? defaultReportsDirectory)
    let f = report.frames
    print(String(format: "✔ %.1f fps (objetivo %.2f), %d/%d fotogramas, %d perdidos · RAM pico %.0f MB · CPU %.0f %% · térmica %@",
                 f.measuredFPS, f.targetFPS, f.rendered, f.expected, f.dropped, report.memory.peakMB,
                 report.cpu.meanPercent, report.thermal.worst.rawValue))
    print(url.path)
} catch {
    FileHandle.standardError.write(Data("minimix-stress: \(error)\n".utf8))
    exit(2)
}
