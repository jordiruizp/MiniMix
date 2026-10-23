import AVFAudio
import AudioToolbox

/// Audio Unit v3 propio (en proceso) que aplica una rampa de ganancia lineal sin clics,
/// mide picos y opcionalmente retarda la señal.
///
/// Por qué un AU propio y no `AVAudioMixerNode.volume`: el volumen del mezclador salta en el
/// siguiente ciclo de render (clic audible). Interpolarlo desde un temporizador da escalones de
/// ≥ 1 buffer y depende del planificador; además no funciona en render manual offline (tests).
/// Aquí la rampa es por muestra, en el propio hilo de audio, y deterministica.
final class RampGainUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("mmrg"),
        componentManufacturer: fourCC("MnMx"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(RampGainUnit.self, as: componentDescription,
                                     name: "MiniMix: RampGain", version: 1)
    }()

    let kernel: RampGainKernel
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        kernel = RampGainKernel(control: RampGainControl())
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw AudioEngineError.invalidFormat
        }
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                            busses: [try AUAudioUnitBus(format: format)])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                             busses: [try AUAudioUnitBus(format: format)])
        maximumFramesToRender = 4_096
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBusses[0].format
        kernel.allocate(maxFrames: Int(maximumFramesToRender), channels: Int(format.channelCount),
                        sampleRate: format.sampleRate)
    }

    override func deallocateRenderResources() {
        kernel.deallocate()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            kernel.prepareOutput(buffers, frameCount: Int(frameCount))
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            kernel.process(buffers, frameCount: Int(frameCount),
                           silent: pullFlags.contains(.unitRenderAction_OutputIsSilence))
            return noErr
        }
    }

    /// Crea un nodo con esta unidad. La configuración se aplica antes de conectarlo al motor
    /// (es decir, antes de `allocateRenderResources`).
    static func makeNode(initialGain: Float, rampSeconds: Double, metering: Bool = false,
                         maxDelaySeconds: Double = 0) -> (node: AVAudioUnitEffect, control: RampGainControl) {
        _ = registration
        let node = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        guard let unit = node.auAudioUnit as? RampGainUnit else {
            preconditionFailure("RampGainUnit no registrada")
        }
        unit.kernel.rampSeconds = rampSeconds
        unit.kernel.metering = metering
        unit.kernel.maxDelaySeconds = maxDelaySeconds
        unit.kernel.control.target = initialGain
        return (node, unit.kernel.control)
    }
}

private func fourCC(_ code: StaticString) -> FourCharCode {
    code.withUTF8Buffer { bytes in bytes.reduce(0) { ($0 << 8) | FourCharCode($1) } }
}
