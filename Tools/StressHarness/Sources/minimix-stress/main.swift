// minimix-stress — harness de estrés y medición (H · T61).
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

struct Options {
    var scenario = "switch-every-3s"
    var duration: Double?
    var fps: FrameRate?
    var size: PixelSize?
    var pipeline = PipelineRegistry.defaultName
    var out = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("reports")
    var list = false
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { if case .usage(let text) = self { text } else { "" } }
}

func parse(_ args: [String]) throws -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    func value(_ flag: String) throws -> String {
        guard let next = iterator.next() else { throw CLIError.usage("falta el valor de \(flag)") }
        return next
    }
    while let arg = iterator.next() {
        switch arg {
        case "--scenario": options.scenario = try value(arg)
        case "--duration": options.duration = Double(try value(arg))
        case "--pipeline": options.pipeline = try value(arg)
        case "--out": options.out = URL(fileURLWithPath: try value(arg))
        case "--list": options.list = true
        case "--fps": options.fps = frameRate(try value(arg))
        case "--size": options.size = try pixelSize(try value(arg))
        case "-h", "--help": throw CLIError.usage("ver la cabecera de Tools/StressHarness/Sources/minimix-stress/main.swift")
        default: throw CLIError.usage("argumento desconocido: \(arg)")
        }
    }
    return options
}

func frameRate(_ text: String) -> FrameRate? {
    switch text {
    case "23.976": FrameRate(24000, 1001)
    case "29.97": .fps29_97
    case "59.94": .fps59_94
    default: Int(text).map { FrameRate($0) }
    }
}

func pixelSize(_ text: String) throws -> PixelSize {
    let parts = text.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { throw CLIError.usage("--size ANCHOxALTO") }
    return PixelSize(width: parts[0], height: parts[1])
}

func loadScenario(_ options: Options) throws -> ScenarioConfig {
    var config: ScenarioConfig
    if let builtIn = ScenarioConfig.named(options.scenario) {
        config = builtIn
    } else if FileManager.default.fileExists(atPath: options.scenario) {
        config = try JSONDecoder().decode(ScenarioConfig.self, from: Data(contentsOf: URL(fileURLWithPath: options.scenario)))
    } else {
        throw CLIError.usage("escenario desconocido: \(options.scenario) (--list)")
    }
    if let duration = options.duration { config.durationSeconds = duration }
    if let fps = options.fps { config.canvas.frameRate = fps }
    if let size = options.size { config.canvas.size = size }
    return config
}

do {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    if options.list {
        print("Escenarios: " + ScenarioConfig.builtIn.map(\.name).joined(separator: ", "))
        print("Pipelines: " + PipelineRegistry.factories.keys.sorted().joined(separator: ", "))
        exit(0)
    }
    let config = try loadScenario(options)
    guard let factory = PipelineRegistry.make(options.pipeline) else {
        throw CLIError.usage("pipeline desconocido: \(options.pipeline)")
    }
    print("▶ \(config.name) · \(factory.name) · \(config.durationSeconds) s · "
          + "\(config.canvas.size.width)x\(config.canvas.size.height)@\(config.canvas.frameRate.fps)")
    let report = try await ScenarioRunner(config: config, factory: factory).run()
    let url = try report.write(to: options.out)
    let f = report.frames
    print(String(format: "✔ %.1f fps (objetivo %.2f), %d/%d fotogramas, %d perdidos · RAM pico %.0f MB · CPU %.0f %% · térmica %@",
                 f.measuredFPS, f.targetFPS, f.rendered, f.expected, f.dropped, report.memory.peakMB,
                 report.cpu.meanPercent, report.thermal.worst.rawValue))
    print(url.path)
} catch {
    FileHandle.standardError.write(Data("minimix-stress: \(error)\n".utf8))
    exit(2)
}
