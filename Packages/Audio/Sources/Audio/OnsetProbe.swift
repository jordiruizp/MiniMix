import AVFAudio
import Core

/// Inicio de un sonido (p. ej. el pitido de la claqueta) detectado a la salida del motor.
public struct AudioOnset: Sendable, Equatable {
    /// Muestra de la salida del motor (contador de render) en la que se supera el umbral.
    public var sampleTime: Int64
    /// Instante del host (s, misma base que `HostTime`/`MasterClock`) de esa muestra según la marca
    /// de tiempo del ciclo de render. nil en render offline.
    public var renderHostTime: Double?
    /// `renderHostTime` + latencia de presentación del dispositivo (`OutputLatency`): cuándo suena.
    public var presentationHostTime: Double?
    /// Pico absoluto de la muestra detectada.
    public var level: Float
}

/// Detector de inicios para medir el sincronismo A/V (diagnóstico, no para producción).
///
/// Se instala con un *tap* en la etapa de salida (tras la compensación de latencia), así que el
/// trabajo se hace fuera del hilo de audio. Un inicio es la primera muestra con |x| ≥ `threshold`
/// después de al menos `holdOff` segundos por debajo.
final class OnsetDetector: @unchecked Sendable {
    // @unchecked: `process` solo lo llama el bloque del tap, que AVAudioEngine invoca en serie en
    // un único hilo; `quietSince` y `armed` no se tocan desde ningún otro sitio.
    private let threshold: Float
    private let holdOffFrames: Int64
    /// Latencia de presentación actual (s); se consulta en cada inicio (no la del arranque: el
    /// dispositivo puede cambiar durante la medición).
    private let presentationLatency: @Sendable () -> Double
    private let continuation: AsyncStream<AudioOnset>.Continuation
    private var lastLoud: Int64 = .min / 2

    init(threshold: Float, holdOffFrames: Int64, presentationLatency: @escaping @Sendable () -> Double,
         continuation: AsyncStream<AudioOnset>.Continuation) {
        self.threshold = threshold
        self.holdOffFrames = holdOffFrames
        self.presentationLatency = presentationLatency
        self.continuation = continuation
    }

    func process(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channels = buffer.floatChannelData, time.isSampleTimeValid else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        let hostSeconds: Double? = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
        for index in 0..<frames {
            var level: Float = 0
            for channel in 0..<channelCount { level = max(level, abs(channels[channel][index])) }
            guard level >= threshold else { continue }
            let sample = time.sampleTime + Int64(index)
            if sample - lastLoud > holdOffFrames {
                let render = hostSeconds.map { $0 + Double(index) / rate }
                let latency = render == nil ? 0 : presentationLatency()
                continuation.yield(AudioOnset(sampleTime: sample, renderHostTime: render,
                                              presentationHostTime: render.map { $0 + latency },
                                              level: level))
            }
            lastLoud = sample
        }
    }

    func finish() { continuation.finish() }
}

extension AudioEngine {
    /// Empieza a detectar inicios de sonido a la salida del motor (medición de sincronismo A/V).
    /// Un único detector a la vez: llamar otra vez sustituye al anterior (y termina su stream).
    /// - Parameters:
    ///   - threshold: nivel absoluto (0…1) a partir del cual hay sonido.
    ///   - holdOff: silencio mínimo (s) entre dos inicios.
    public func startOnsetDetection(threshold: Float = 0.3, holdOff: Double = 0.5) -> AsyncStream<AudioOnset> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioOnset.self, bufferingPolicy: .unbounded)
        let latency: @Sendable () -> Double = { [weak self] in self?.outputLatency?.presentationSeconds ?? 0 }
        installOutputTap { node, format in
            let detector = OnsetDetector(threshold: threshold,
                                         holdOffFrames: Int64((holdOff * format.sampleRate).rounded()),
                                         presentationLatency: latency, continuation: continuation)
            node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, time in
                detector.process(buffer, at: time)
            }
            return detector
        }
        return stream
    }

    /// Quita el detector de inicios (si lo hay) y termina su stream.
    public func stopOnsetDetection() {
        installOutputTap(nil)
    }
}
