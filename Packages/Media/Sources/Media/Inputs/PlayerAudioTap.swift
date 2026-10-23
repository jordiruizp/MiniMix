import AVFoundation
import MediaToolbox

/// Saca el audio de un `AVPlayerItem` hacia el `AVAudioEngine` de Audio (E):
/// `MTAudioProcessingTap` (en el `audioMix` del item) → `AudioRingBuffer` →
/// `AVAudioSourceNode` (`node`). El tap deja en silencio la salida directa del
/// reproductor, así que el audio solo suena a través del motor (volumen, mute,
/// solo y fundidos los aplica E sobre `node`).
final class PlayerAudioTap: Sendable {
    let node: AVAudioSourceNode
    let ring: AudioRingBuffer

    private init(node: AVAudioSourceNode, ring: AudioRingBuffer) {
        self.node = node
        self.ring = ring
    }

    /// Crea el puente y el `AVAudioMix` que hay que asignar al item.
    /// `sampleRate` y `channels` son los de la pista (el tap entrega la frecuencia de la pista).
    static func make(track: AVAssetTrack, sampleRate: Double, channels: Int) throws -> (PlayerAudioTap, AVAudioMix) {
        let ring = AudioRingBuffer(channels: min(max(channels, 1), 2), sampleRate: sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(ring.channels)) else {
            throw MediaError.noPlayableTrack("formato de audio no soportado (\(sampleRate) Hz)")
        }
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, data in
            let list = UnsafeMutableAudioBufferListPointer(data)
            let got = ring.read(into: list, frames: Int(frameCount))
            if got == 0 { isSilence.pointee = true }
            return noErr
        }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(ring).toOpaque(),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: nil, process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(ring).release()
            throw MediaError.noPlayableTrack("MTAudioProcessingTapCreate: \(status)")
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return (PlayerAudioTap(node: node, ring: ring), mix)
    }
}

// MARK: - Callbacks C del tap (sin capturas)

private func tapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                     _ storageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    storageOut.pointee = clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<AudioRingBuffer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func tapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                        _ format: UnsafePointer<AudioStreamBasicDescription>) {
    Unmanaged<AudioRingBuffer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .sourceFormat = format.pointee
}

private func tapProcess(_ tap: MTAudioProcessingTap, _ frames: CMItemCount, _ flags: MTAudioProcessingTapFlags,
                        _ bufferList: UnsafeMutablePointer<AudioBufferList>,
                        _ framesOut: UnsafeMutablePointer<CMItemCount>,
                        _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else {
        framesOut.pointee = 0
        return
    }
    let ring = Unmanaged<AudioRingBuffer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let list = UnsafeMutableAudioBufferListPointer(bufferList)
    ring.write(list, frames: Int(framesOut.pointee))
    // Silenciar la salida directa del AVPlayer: el audio va por el motor de E.
    for buffer in list {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
}
