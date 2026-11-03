import AVFoundation
import Foundation
@testable import Media

/// Mide la sincronía A/V de un `VideoInput` con un motor de audio en tiempo real:
/// detecta los clics del archivo en lo que renderiza su nodo y compara el instante
/// en que sonarán (host del render + latencia de salida) con el tiempo de item que
/// muestra el vídeo en ese instante (`itemTime(forHostTime:)`, el mismo que usa
/// `texture(for:)`). Error > 0 = el audio llega tarde.
final class AVSyncProbe {
    struct Onset {
        /// Segundos desde `play()`.
        let sincePlay: Double
        let clickTime: Double
        let errorMs: Double
    }

    private let engine = AVAudioEngine()
    private let node: AVAudioNode
    private let captured = LockedState<[(host: Double, samples: [Float])]>([])
    let sampleRate: Double

    init?(node: AVAudioNode) {
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount > 0 else { return nil }
        sampleRate = output.sampleRate
        self.node = node
        let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 2)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0 // no suena en los altavoces
        let captured = self.captured
        node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, when in
            guard when.isHostTimeValid, let data = buffer.floatChannelData?[0] else { return }
            let host = AVAudioTime.seconds(forHostTime: when.hostTime)
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            captured.withLock { $0.append((host, samples)) }
        }
        do { try engine.start() } catch { return nil }
    }

    var outputLatency: Double { engine.outputNode.presentationLatency }

    func reset() { captured.withLock { $0.removeAll() } }

    func stop() {
        node.removeTap(onBus: 0)
        engine.stop()
    }

    /// Onsets detectados, con su error respecto al vídeo.
    func onsets(input: VideoInput, playHost: Double) -> [Onset] {
        let latency = outputLatency
        var result: [Onset] = []
        var quiet = 0
        for chunk in captured.current {
            for (i, sample) in chunk.samples.enumerated() {
                if abs(sample) > 0.2, quiet > Int(sampleRate * 0.05) {
                    let heard = chunk.host + Double(i) / sampleRate + latency
                    if let item = input.itemTimeForTesting(hostSeconds: heard) {
                        let k = ((item - TestMediaFactory.VideoSpec.clickOffset) / TestMediaFactory.VideoSpec.clickInterval)
                            .rounded()
                        let click = TestMediaFactory.VideoSpec.clickOffset + k * TestMediaFactory.VideoSpec.clickInterval
                        result.append(Onset(sincePlay: heard - playHost, clickTime: click, errorMs: (item - click) * 1000))
                    }
                }
                quiet = abs(sample) > 0.05 ? 0 : quiet + 1
            }
        }
        return result
    }
}
