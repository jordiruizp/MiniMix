import AudioToolbox

/// Procesado de una etapa de ganancia: rampa lineal de ganancia, medidor de pico y
/// (opcional) línea de retardo para la compensación de latencia.
///
/// Concurrencia: la configuración (`rampSeconds`, `metering`, `maxDelaySeconds`) se fija antes de
/// `allocate`; después, `process` solo se llama desde el hilo de audio y es la única que toca el
/// estado mutable. La comunicación con el control es solo a través de `RampGainControl` (atómicos).
/// `process` no asigna memoria, no toma cerrojos y no hace E/S.
final class RampGainKernel {
    let control: RampGainControl
    var rampSeconds: Double = 0.02
    var delayFadeSeconds: Double = 0.01
    var metering = false
    /// 0 = sin línea de retardo.
    var maxDelaySeconds: Double = 0

    // Rampa
    private var rampFrames = 960
    private var gain: Float = 1
    private var lastTarget: Float = 1
    private var step: Float = 0
    private var remaining = 0

    // Búfer propio para cuando el host entrega `mData == nil`.
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchFrames = 0
    private var scratchChannels = 0

    // Línea de retardo (un anillo por canal).
    private var ring: UnsafeMutablePointer<Float>?
    private var ringFrames = 0
    private var ringChannels = 0
    private var maxDelayFrames = 0
    private var writeIndex = 0
    private var currentDelay = 0
    private var fade: Float = 1
    private var fadeStep: Float = 1

    private(set) var sampleRate: Double = 48_000

    init(control: RampGainControl) {
        self.control = control
    }

    deinit { deallocate() }

    func allocate(maxFrames: Int, channels: Int, sampleRate: Double) {
        deallocate()
        self.sampleRate = sampleRate
        rampFrames = max(1, Int((rampSeconds * sampleRate).rounded()))
        gain = control.target
        lastTarget = gain
        remaining = 0
        control.storeApplied(gain)

        scratchFrames = max(1, maxFrames)
        scratchChannels = max(1, channels)
        let scratchBuffer = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * scratchChannels)
        scratchBuffer.initialize(repeating: 0, count: scratchFrames * scratchChannels)
        scratch = scratchBuffer

        maxDelayFrames = max(0, Int((maxDelaySeconds * sampleRate).rounded()))
        if maxDelayFrames > 0 {
            ringFrames = maxDelayFrames + 1
            ringChannels = max(1, channels)
            let ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: ringFrames * ringChannels)
            ringBuffer.initialize(repeating: 0, count: ringFrames * ringChannels)
            ring = ringBuffer
            writeIndex = 0
            currentDelay = min(control.delayFrames, maxDelayFrames)
            fade = 1
            fadeStep = 1 / Float(max(1, Int((delayFadeSeconds * sampleRate).rounded())))
        }
    }

    /// Máximo de muestras por ciclo de render (tamaño del búfer propio).
    var capacityFrames: Int { scratch == nil ? 0 : scratchFrames }

    func deallocate() {
        scratch?.deallocate()
        scratch = nil
        ring?.deallocate()
        ring = nil
        ringFrames = 0
        maxDelayFrames = 0
    }

    /// Hilo de audio: da memoria propia a los búferes de salida que lleguen sin ella.
    func prepareOutput(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard let scratch else { return }
        for index in 0..<buffers.count where buffers[index].mData == nil {
            let channel = min(index, scratchChannels - 1)
            buffers[index].mData = UnsafeMutableRawPointer(scratch + channel * scratchFrames)
            buffers[index].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        }
    }

    /// Hilo de audio: aplica rampa de ganancia, medidor y retardo en el sitio.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, silent: Bool) {
        let target = control.target
        if target != lastTarget {
            // Nueva rampa desde la ganancia actual (aunque haya otra en curso).
            lastTarget = target
            remaining = rampFrames
            step = (target - gain) / Float(rampFrames)
        }
        let desiredDelay = min(control.delayFrames, maxDelayFrames)

        // Cada canal parte del mismo estado y lo recorre igual (determinista); se confirma al final.
        var endGain = gain
        var endRemaining = remaining
        var endWrite = writeIndex
        var endDelay = currentDelay
        var endFade = fade

        for channel in 0..<buffers.count {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            if silent { data.update(repeating: 0, count: frameCount) }
            var currentGain = gain
            var rampLeft = remaining
            var peak: Float = 0
            for index in 0..<frameCount {
                if rampLeft > 0 {
                    rampLeft -= 1
                    currentGain = rampLeft == 0 ? lastTarget : currentGain + step
                }
                let sample = data[index] * currentGain
                peak = max(peak, abs(sample))
                data[index] = sample
            }
            if metering { control.recordPeak(peak, channel: channel) }
            endGain = currentGain
            endRemaining = rampLeft

            if let ring, channel < ringChannels {
                let end = delay(data, frameCount: frameCount, line: ring + channel * ringFrames,
                                desired: desiredDelay)
                endWrite = end.write
                endDelay = end.delay
                endFade = end.fade
            }
        }
        gain = endGain
        remaining = endRemaining
        writeIndex = endWrite
        currentDelay = endDelay
        fade = endFade
        control.storeApplied(gain)
    }

    /// Retardo de un canal. Al cambiar el retardo se funde a 0, se cambia y se vuelve a 1 (sin clic).
    private func delay(_ data: UnsafeMutablePointer<Float>, frameCount: Int,
                       line: UnsafeMutablePointer<Float>, desired: Int) -> DelayState {
        var write = writeIndex
        var delayFrames = currentDelay
        var fadeGain = fade
        for index in 0..<frameCount {
            if delayFrames != desired {
                fadeGain -= fadeStep
                if fadeGain <= 0 {
                    fadeGain = 0
                    delayFrames = desired
                }
            } else if fadeGain < 1 {
                fadeGain = min(1, fadeGain + fadeStep)
            }
            line[write] = data[index]
            var read = write - delayFrames
            if read < 0 { read += ringFrames }
            data[index] = line[read] * fadeGain
            write += 1
            if write == ringFrames { write = 0 }
        }
        return DelayState(write: write, delay: delayFrames, fade: fadeGain)
    }

    private struct DelayState {
        var write: Int
        var delay: Int
        var fade: Float
    }
}
