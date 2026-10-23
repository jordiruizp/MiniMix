import AVFAudio
import Core
import CoreMocks
@testable import Audio

let testSampleRate: Double = 48_000
let testChunk: AVAudioFrameCount = 512

/// Estado de un generador de prueba. Solo lo toca el hilo de render de su `AVAudioSourceNode`
/// (y, en modo offline, ese hilo es el que llama a `renderOffline`): por eso `@unchecked Sendable`.
final class SignalState: @unchecked Sendable {
    var frame = 0
}

/// Señales de prueba deterministas.
enum TestSignal {
    /// Seno de `frequency` Hz con amplitud `amplitude` (fase exacta: contador entero de muestras).
    case sine(frequency: Double, amplitude: Float)
    /// 0 hasta `start` y luego `level` constante.
    case step(start: Int, level: Float)
    case silence

    func value(at frame: Int) -> Float {
        switch self {
        case let .sine(frequency, amplitude):
            let period = testSampleRate / frequency
            let phase = Double(frame).truncatingRemainder(dividingBy: period) / period
            return amplitude * Float(sin(2 * Double.pi * phase))
        case let .step(start, level):
            return frame >= start ? level : 0
        case .silence:
            return 0
        }
    }
}

/// Crea una fuente (`MockAudioSource`) con un `AVAudioSourceNode` real que genera `signal`.
func makeSource(_ signal: TestSignal, id: InputID = InputID()) -> MockAudioSource {
    let format = AVAudioFormat(standardFormatWithSampleRate: testSampleRate, channels: 2)!
    let state = SignalState()
    let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let start = state.frame
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for index in 0..<Int(frameCount) { data[index] = signal.value(at: start + index) }
        }
        state.frame += Int(frameCount)
        return noErr
    }
    return MockAudioSource(id: id, node: node)
}

func makeOfflineEngine(meterRate: Double = 0, maxLatency: Double = 1) throws -> AudioEngine {
    try AudioEngine(configuration: AudioEngineConfiguration(
        renderMode: .offline(sampleRate: testSampleRate, maximumFrameCount: testChunk),
        meterRate: meterRate,
        maxLatencyCompensation: maxLatency
    ))
}

/// Renderiza `frames` muestras y devuelve el canal izquierdo.
func render(_ engine: AudioEngine, frames: Int) throws -> [Float] {
    let format = AVAudioFormat(standardFormatWithSampleRate: testSampleRate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: testChunk)!
    var out: [Float] = []
    out.reserveCapacity(frames)
    var left = frames
    while left > 0 {
        let count = AVAudioFrameCount(min(left, Int(testChunk)))
        let status = try engine.renderOffline(count, to: buffer)
        precondition(status == .success, "render offline: \(status.rawValue)")
        let data = buffer.floatChannelData![0]
        out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        left -= Int(buffer.frameLength)
    }
    return out
}

/// Pico absoluto de las últimas `count` muestras.
func peak(_ samples: [Float], last count: Int) -> Float {
    samples.suffix(count).map(abs).max() ?? 0
}

/// Envolvente: máximo de |x| en una ventana deslizante de `window` muestras (un periodo del seno).
func envelope(_ samples: [Float], window: Int) -> [Float] {
    guard samples.count >= window else { return [] }
    return (window - 1..<samples.count).map { end in
        var maximum: Float = 0
        for index in (end - window + 1)...end { maximum = max(maximum, abs(samples[index])) }
        return maximum
    }
}

/// Mayor salto entre muestras consecutivas de la envolvente.
func maxEnvelopeJump(_ env: [Float]) -> Float {
    zip(env.dropFirst(), env).map { abs($0 - $1) }.max() ?? 0
}
