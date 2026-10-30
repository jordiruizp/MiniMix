import AudioToolbox

/// Propietario de los recursos de una etapa de ganancia: rampa lineal de ganancia, medidor de
/// pico y (opcional) línea de retardo para la compensación de latencia.
///
/// Concurrencia: la configuración (`rampSeconds`, `metering`, `maxDelaySeconds`) se fija antes de
/// `allocate`. El estado de render vive en `dsp`, un `UnsafeMutablePointer<RampGainDSP>` (struct
/// POD, sin referencias): el render block captura el puntero y `control`, así que en el hilo de
/// audio no hay accesos a propiedades de clase (ni comprobaciones dinámicas de exclusividad, ni
/// retain/release del kernel). `allocate`/`deallocate` solo se llaman con el render parado.
final class RampGainKernel {
    let control: RampGainControl
    var rampSeconds: Double = 0.02
    var delayFadeSeconds: Double = 0.01
    var metering = false
    /// 0 = sin línea de retardo.
    var maxDelaySeconds: Double = 0

    /// Estado del hilo de audio. Vive lo mismo que el kernel (y el kernel lo mismo que la unidad,
    /// que es quien entrega el render block).
    let dsp: UnsafeMutablePointer<RampGainDSP>

    init(control: RampGainControl) {
        self.control = control
        dsp = .allocate(capacity: 1)
        dsp.initialize(to: RampGainDSP())
    }

    deinit {
        deallocate()
        dsp.deinitialize(count: 1)
        dsp.deallocate()
    }

    /// Máximo de muestras por ciclo de render (0 sin recursos asignados).
    var capacityFrames: Int { dsp.pointee.capacityFrames }

    func allocate(maxFrames: Int, channels: Int, sampleRate: Double) {
        deallocate()
        var state = RampGainDSP()
        state.metering = metering
        state.rampFrames = max(1, Int((rampSeconds * sampleRate).rounded()))
        state.gain = control.target
        state.lastTarget = state.gain
        control.storeApplied(state.gain)

        state.scratchFrames = max(1, maxFrames)
        state.scratchChannels = max(1, channels)
        let scratchCount = state.scratchFrames * state.scratchChannels
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCount)
        scratch.initialize(repeating: 0, count: scratchCount)
        state.scratch = scratch

        state.maxDelayFrames = max(0, Int((maxDelaySeconds * sampleRate).rounded()))
        if state.maxDelayFrames > 0 {
            state.ringFrames = state.maxDelayFrames + 1
            state.ringChannels = max(1, channels)
            let ringCount = state.ringFrames * state.ringChannels
            let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringCount)
            ring.initialize(repeating: 0, count: ringCount)
            state.ring = ring
            state.currentDelay = min(control.delayFrames, state.maxDelayFrames)
            state.fadeStep = 1 / Float(max(1, Int((delayFadeSeconds * sampleRate).rounded())))
        }
        dsp.pointee = state
    }

    func deallocate() {
        dsp.pointee.scratch?.deallocate()
        dsp.pointee.ring?.deallocate()
        dsp.pointee = RampGainDSP()
    }
}

/// Estado y proceso del hilo de audio. Struct POD (solo números y punteros): se usa siempre a
/// través de `RampGainKernel.dsp`. Sin asignaciones, cerrojos ni E/S.
struct RampGainDSP {
    var metering = false

    // Rampa
    var rampFrames = 960
    var gain: Float = 1
    var lastTarget: Float = 1
    var step: Float = 0
    var remaining = 0

    // Búfer propio para cuando el host entrega `mData == nil`.
    var scratch: UnsafeMutablePointer<Float>?
    var scratchFrames = 0
    var scratchChannels = 0

    // Línea de retardo (un anillo por canal).
    var ring: UnsafeMutablePointer<Float>?
    var ringFrames = 0
    var ringChannels = 0
    var maxDelayFrames = 0
    var writeIndex = 0
    var currentDelay = 0
    var fade: Float = 1
    var fadeStep: Float = 1

    var capacityFrames: Int { scratch == nil ? 0 : scratchFrames }

    /// Da memoria propia a los búferes de salida que lleguen sin ella.
    func prepareOutput(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard let scratch else { return }
        for index in 0..<buffers.count where buffers[index].mData == nil {
            let channel = min(index, scratchChannels - 1)
            buffers[index].mData = UnsafeMutableRawPointer(scratch + channel * scratchFrames)
            buffers[index].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        }
    }

    /// Aplica retardo, rampa de ganancia y medidor (en ese orden), en el sitio.
    mutating func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, silent: Bool,
                          control: RampGainControl) {
        let target = control.target
        if target != lastTarget {
            // Nueva rampa desde la ganancia actual (aunque haya otra en curso).
            lastTarget = target
            remaining = rampFrames
            step = (target - gain) / Float(rampFrames)
        }
        let desiredDelay = min(control.delayFrames, maxDelayFrames)
        // Copias locales: cada canal parte del mismo estado y lo recorre igual (determinista).
        let startGain = gain, startRemaining = remaining, rampStep = step, rampTarget = lastTarget
        let start = DelayState(write: writeIndex, delay: currentDelay, fade: fade)
        var endGain = startGain
        var endRemaining = startRemaining
        var end = start

        for channel in 0..<buffers.count {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            if silent { data.update(repeating: 0, count: frameCount) }
            // El retardo va antes de la ganancia y del medidor: así un fader/mute (o la rampa de
            // baja de un canal) actúa sobre lo que sale ya, no `delay` más tarde, y el vúmetro
            // mide lo que se oye.
            if let ring, channel < ringChannels {
                end = Self.delay(data, frameCount: frameCount, line: ring + channel * ringFrames,
                                 ringFrames: ringFrames, from: start, desired: desiredDelay, fadeStep: fadeStep)
            }
            var currentGain = startGain
            var rampLeft = startRemaining
            var peak: Float = 0
            for index in 0..<frameCount {
                if rampLeft > 0 {
                    rampLeft -= 1
                    currentGain = rampLeft == 0 ? rampTarget : currentGain + rampStep
                }
                let sample = data[index] * currentGain
                peak = max(peak, abs(sample))
                data[index] = sample
            }
            if metering { control.recordPeak(peak, channel: channel) }
            endGain = currentGain
            endRemaining = rampLeft
        }
        gain = endGain
        remaining = endRemaining
        writeIndex = end.write
        currentDelay = end.delay
        fade = end.fade
        control.storeApplied(endGain)
    }

    struct DelayState {
        var write: Int
        var delay: Int
        var fade: Float
    }

    // swiftlint:disable function_parameter_count
    /// Retardo de un canal. Al cambiar el retardo se funde a 0, se cambia y se vuelve a 1 (sin clic).
    static func delay(_ data: UnsafeMutablePointer<Float>, frameCount: Int, line: UnsafeMutablePointer<Float>,
                      ringFrames: Int, from start: DelayState, desired: Int, fadeStep: Float) -> DelayState {
        var write = start.write
        var delayFrames = start.delay
        var fadeGain = start.fade
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
    // swiftlint:enable function_parameter_count
}
