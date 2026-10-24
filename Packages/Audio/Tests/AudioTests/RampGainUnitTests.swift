import AudioToolbox
import AVFAudio
import Foundation
import Testing
@testable import Audio

/// Pruebas directas de la unidad (sin `AVAudioEngine`): se llama a su render block.
@Suite struct RampGainUnitTests {
    static let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    static func makeUnit(maxFrames: AUAudioFrameCount = 512) throws -> RampGainUnit {
        let unit = try RampGainUnit(componentDescription: RampGainUnit.componentDescription)
        unit.maximumFramesToRender = maxFrames
        return unit
    }

    /// Llama al render block con una entrada constante `value` (y opcionalmente marcada como silencio).
    static func renderDirect(_ unit: RampGainUnit, frames: AVAudioFrameCount, value: Float,
                             silent: Bool = false, into buffer: AVAudioPCMBuffer) -> AUAudioUnitStatus {
        buffer.frameLength = buffer.frameCapacity
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let pull: AURenderPullInputBlock = { pullFlags, _, count, _, data in
            for audioBuffer in UnsafeMutableAudioBufferListPointer(data) {
                audioBuffer.mData?.assumingMemoryBound(to: Float.self).update(repeating: value, count: Int(count))
            }
            if silent { pullFlags.pointee.insert(.unitRenderAction_OutputIsSilence) }
            return noErr
        }
        return unit.internalRenderBlock(&flags, &timestamp, frames, 0, buffer.mutableAudioBufferList, nil, pull)
    }

    @Test func rejectsMismatchedFormats() throws {
        let unit = try Self.makeUnit()
        try unit.inputBusses[0].setFormat(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        try unit.outputBusses[0].setFormat(Self.stereo)
        #expect {
            try unit.allocateRenderResources()
        } throws: { error in
            (error as NSError).domain == NSOSStatusErrorDomain
                && (error as NSError).code == Int(kAudioUnitErr_FormatNotSupported)
        }

        let other = try Self.makeUnit()
        try other.inputBusses[0].setFormat(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        try other.outputBusses[0].setFormat(Self.stereo)
        #expect(throws: (any Error).self) { try other.allocateRenderResources() }
    }

    @Test func rejectsTooManyFrames() throws {
        let unit = try Self.makeUnit(maxFrames: 64)
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.stereo, frameCapacity: 256)!
        #expect(Self.renderDirect(unit, frames: 128, value: 0.5, into: buffer) == kAudioUnitErr_TooManyFramesToProcess)
        #expect(Self.renderDirect(unit, frames: 64, value: 0.5, into: buffer) == noErr)
        #expect(buffer.floatChannelData![0][63] == 0.5)
    }

    /// Rama `OutputIsSilence`: la entrada marcada como silencio se trata como ceros aunque el búfer
    /// traiga basura, y no cuenta para el vúmetro.
    @Test func silenceFlagZeroesOutputAndMeter() throws {
        let unit = try Self.makeUnit()
        unit.kernel.metering = true
        unit.kernel.control.target = 0.5
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.stereo, frameCapacity: 256)!

        #expect(Self.renderDirect(unit, frames: 256, value: 1, silent: true, into: buffer) == noErr)
        for channel in 0..<2 {
            #expect(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: 256).allSatisfy { $0 == 0 })
        }
        #expect(unit.kernel.control.takePeaks() == [0, 0])

        #expect(Self.renderDirect(unit, frames: 256, value: 1, into: buffer) == noErr)
        #expect(buffer.floatChannelData![1][255] == 0.5)
        #expect(unit.kernel.control.takePeaks() == [0.5, 0.5])
    }

    /// El render block mantiene vivo el kernel (y su estado) aunque se suelte la unidad: al
    /// destruirse, la unidad libera sus recursos de render y el bloque rehúsa con un error en
    /// lugar de leer memoria liberada.
    @Test func renderBlockOutlivesUnit() throws {
        var unit: RampGainUnit? = try Self.makeUnit()
        try unit?.allocateRenderResources()
        let block = try #require(unit?.internalRenderBlock)
        unit = nil
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.stereo, frameCapacity: 64)!
        buffer.frameLength = 64
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let status = block(&flags, &timestamp, 64, 0, buffer.mutableAudioBufferList, nil) { _, _, count, _, data in
            for audioBuffer in UnsafeMutableAudioBufferListPointer(data) {
                audioBuffer.mData?.assumingMemoryBound(to: Float.self).update(repeating: 0.25, count: Int(count))
            }
            return noErr
        }
        #expect(status == kAudioUnitErr_TooManyFramesToProcess)
    }

    /// App Sandbox solo instancia en proceso componentes `sandboxSafe` (sin la marca: -3000 y
    /// excepción ObjC). `swift test` no corre en sandbox; la verificación con sandbox real se hace
    /// con un .app firmado con `App/Resources/MiniMix.entitlements` (ver informe de la tarea).
    @Test func componentIsSandboxSafeAndInstantiable() throws {
        let flags = AudioComponentFlags(rawValue: RampGainUnit.componentDescription.componentFlags)
        #expect(flags.contains(.sandboxSafe))
        _ = try RampGainUnit.makeNode(initialGain: 1, rampSeconds: 0.02)
        #expect(RampGainUnit.instantiationStatus(for: RampGainUnit.componentDescription) == noErr)
    }

    /// La comprobación previa devuelve un `OSStatus` (no lanza excepciones ObjC) si el componente
    /// no existe; `makeNode` lo convierte en `AudioEngineError.audioUnitUnavailable`.
    @Test func unknownComponentReportsStatusInsteadOfRaising() {
        var missing = RampGainUnit.componentDescription
        missing.componentSubType = 0x6e6f6e65 // 'none'
        #expect(RampGainUnit.instantiationStatus(for: missing) == RampGainUnit.invalidComponentID)
    }
}
