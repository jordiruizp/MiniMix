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
    /// `sandboxSafe` es imprescindible: con App Sandbox, AudioToolbox solo instancia en proceso los
    /// componentes marcados así; sin la marca la creación falla con -3000 (invalidComponentID) y
    /// `AVAudioUnitEffect(audioComponentDescription:)` lanza una excepción ObjC que termina la app.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("mmrg"),
        componentManufacturer: fourCC("MnMx"),
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask: 0
    )

    /// Registro (una vez) y comprobación de que el componente se puede instanciar, con la API C que
    /// devuelve `OSStatus` en lugar de lanzar excepciones ObjC.
    private static let availability: OSStatus = {
        AUAudioUnit.registerSubclass(RampGainUnit.self, as: componentDescription,
                                     name: "MiniMix: RampGain", version: 1)
        return instantiationStatus(for: componentDescription)
    }()

    /// -3000 («invalidComponentID»): lo que devuelve AudioToolbox con sandbox para un componente sin
    /// `sandboxSafe` (la constante no está en las cabeceras públicas del SDK).
    static let invalidComponentID: OSStatus = -3000

    /// `noErr` si `description` se puede instanciar en este proceso (sandbox incluido).
    static func instantiationStatus(for description: AudioComponentDescription) -> OSStatus {
        var search = description
        guard let component = AudioComponentFindNext(nil, &search) else {
            return RampGainUnit.invalidComponentID
        }
        var instance: AudioComponentInstance?
        let status = AudioComponentInstanceNew(component, &instance)
        if let instance { AudioComponentInstanceDispose(instance) }
        return status
    }

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
        // El proceso es en el sitio: entrada y salida deben tener el mismo formato, Float32 no
        // entrelazado (un búfer por canal).
        let input = inputBusses[0].format
        let format = outputBusses[0].format
        guard input.sampleRate == format.sampleRate, input.channelCount == format.channelCount,
              format.commonFormat == .pcmFormatFloat32, input.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved, !input.isInterleaved else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        kernel.allocate(maxFrames: Int(maximumFramesToRender), channels: Int(format.channelCount),
                        sampleRate: format.sampleRate)
    }

    override func deallocateRenderResources() {
        kernel.deallocate()
        super.deallocateRenderResources()
    }

    /// Vida útil: el bloque captura `kernel` (no solo su puntero) para que `dsp` no se libere
    /// mientras el bloque exista, aunque la unidad se suelte antes. `deallocateRenderResources`
    /// (que reinicia `dsp`) nunca corre a la vez que el render: el host deja de renderizar antes
    /// de llamarlo (contrato de `AUAudioUnit`), y `AVAudioEngine` lo hace al parar o reconectar.
    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = kernel
        let dsp = kernel.dsp
        let control = kernel.control
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            withExtendedLifetime(kernel) {
                guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
                guard Int(frameCount) <= dsp.pointee.capacityFrames else {
                    return kAudioUnitErr_TooManyFramesToProcess
                }
                let buffers = UnsafeMutableAudioBufferListPointer(outputData)
                dsp.pointee.prepareOutput(buffers, frameCount: Int(frameCount))
                var pullFlags = AudioUnitRenderActionFlags()
                let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
                guard status == noErr else { return status }
                dsp.pointee.process(buffers, frameCount: Int(frameCount),
                                    silent: pullFlags.contains(.unitRenderAction_OutputIsSilence), control: control)
                return noErr
            }
        }
    }

    /// Crea un nodo con esta unidad. La configuración se aplica antes de conectarlo al motor
    /// (es decir, antes de `allocateRenderResources`). Lanza `audioUnitUnavailable` (error Swift)
    /// si el componente no se puede instanciar: nunca llega a `AVAudioUnitEffect` en ese caso.
    static func makeNode(initialGain: Float, rampSeconds: Double, metering: Bool = false,
                         maxDelaySeconds: Double = 0) throws -> (node: AVAudioUnitEffect, control: RampGainControl) {
        guard availability == noErr else { throw AudioEngineError.audioUnitUnavailable(availability) }
        let node = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        guard let unit = node.auAudioUnit as? RampGainUnit else {
            throw AudioEngineError.audioUnitUnavailable(RampGainUnit.invalidComponentID)
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
