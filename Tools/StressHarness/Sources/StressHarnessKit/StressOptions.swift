import Core
import Foundation

/// Opciones de línea de órdenes de `minimix-stress`.
public struct StressOptions: Equatable, Sendable {
    public enum UsageError: Error, Equatable, CustomStringConvertible {
        case usage(String)
        public var description: String { if case .usage(let text) = self { text } else { "" } }
    }

    public var scenario = "switch-every-3s"
    public var duration: Double?
    public var fps: FrameRate?
    public var size: PixelSize?
    public var pipeline = PipelineRegistry.defaultName
    /// nil = `Tools/reports`.
    public var out: URL?
    public var list = false

    public init() {}

    public static func parse(_ args: [String]) throws -> StressOptions {
        var options = StressOptions()
        var iterator = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw UsageError.usage("falta el valor de \(flag)") }
            return next
        }
        while let arg = iterator.next() {
            switch arg {
            case "--scenario": options.scenario = try value(arg)
            case "--duration": options.duration = try duration(try value(arg))
            case "--pipeline": options.pipeline = try value(arg)
            case "--out": options.out = URL(fileURLWithPath: try value(arg))
            case "--list": options.list = true
            case "--fps": options.fps = try frameRate(try value(arg))
            case "--size": options.size = try pixelSize(try value(arg))
            case "-h", "--help":
                throw UsageError.usage("ver la cabecera de Tools/StressHarness/Sources/minimix-stress/main.swift")
            default: throw UsageError.usage("argumento desconocido: \(arg)")
            }
        }
        return options
    }

    static func duration(_ text: String) throws -> Double {
        guard let seconds = Double(text), seconds.isFinite, seconds > 0 else {
            throw UsageError.usage("--duration necesita segundos > 0 (recibido «\(text)»)")
        }
        return seconds
    }

    static func frameRate(_ text: String) throws -> FrameRate {
        switch text {
        case "23.976": return FrameRate(24000, 1001)
        case "29.97": return .fps29_97
        case "59.94": return .fps59_94
        default:
            guard let fps = Int(text), (1...240).contains(fps) else {
                throw UsageError.usage("--fps admite 23.976, 29.97, 59.94 o un entero 1…240 (recibido «\(text)»)")
            }
            return FrameRate(fps)
        }
    }

    static func pixelSize(_ text: String) throws -> PixelSize {
        let parts = text.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts.allSatisfy({ (16...8192).contains($0) }) else {
            throw UsageError.usage("--size ANCHOxALTO (16…8192), recibido «\(text)»")
        }
        return PixelSize(width: parts[0], height: parts[1])
    }
}
