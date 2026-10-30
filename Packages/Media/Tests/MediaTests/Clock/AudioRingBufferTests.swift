import AudioToolbox
import Darwin
import Testing
@testable import Media

@Suite struct AudioRingBufferTests {
    private func withList(frames: Int, _ body: (UnsafeMutableAudioBufferListPointer) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        let data = [UnsafeMutablePointer<Float>.allocate(capacity: frames), UnsafeMutablePointer<Float>.allocate(capacity: frames)]
        for (i, d) in data.enumerated() {
            d.initialize(repeating: 0.5, count: frames)
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: d)
        }
        body(list)
        data.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    private func planarFloat(_ rate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
    }

    @Test func roundTrip() {
        let ring = AudioRingBuffer(channels: 2, sampleRate: 48_000)
        ring.sourceFormat = planarFloat(48_000)
        withList(frames: 256) { ring.write($0, frames: 256) }
        #expect(ring.availableFrames == 256)
        withList(frames: 256) { out in
            out[0].mData!.assumingMemoryBound(to: Float.self).update(repeating: 0, count: 256)
            #expect(ring.read(into: out, frames: 256) == 256)
            #expect(out[0].mData!.assumingMemoryBound(to: Float.self)[100] == 0.5)
        }
    }

    // MARK: Alineación por tiempo de item

    private func filledRing(itemTime: Double, frames: Int = 4_800) -> AudioRingBuffer {
        let ring = AudioRingBuffer(channels: 2, sampleRate: 48_000)
        ring.sourceFormat = planarFloat(48_000)
        withList(frames: frames) { ring.write($0, frames: frames, itemTime: itemTime) }
        return ring
    }

    /// Lee y devuelve (muestras reales, silencio inicial).
    private func readAligned(_ ring: AudioRingBuffer, desired: Double, frames: Int = 480) -> (Int, Int) {
        var result = (0, 0)
        withList(frames: frames) { out in
            let got = ring.read(into: out, frames: frames, desiredItemTime: desired)
            let data = out[0].mData!.assumingMemoryBound(to: Float.self)
            result = (got, (0..<frames).prefix { data[$0] == 0 }.count)
        }
        return result
    }

    /// Audio que llega tarde (arranque): se descarta lo atrasado y suena lo que toca.
    @Test func lateAudioIsDropped() {
        let ring = filledRing(itemTime: 1.0) // 1,0…1,1 s
        let (got, silence) = readAligned(ring, desired: 1.05)
        #expect(got == 480 && silence == 0)
        #expect(ring.droppedLateFrames.load(ordering: .relaxed) == 2_400)
        #expect(ring.availableFrames == 4_800 - 2_400 - 480)
    }

    /// Audio que llega pronto: se retiene (silencio delante) hasta su instante.
    @Test func earlyAudioIsHeld() {
        let ring = filledRing(itemTime: 1.0)
        let (got, silence) = readAligned(ring, desired: 0.995) // 5 ms antes
        #expect(silence == 240 && got == 240)
        #expect(ring.availableFrames == 4_800 - 240)
    }

    /// Dentro de la tolerancia (2 ms) no se corrige: sin micro-cortes por jitter.
    @Test func smallDifferencesAreIgnored() {
        let ring = filledRing(itemTime: 1.0)
        let (got, silence) = readAligned(ring, desired: 1.001)
        #expect(got == 480 && silence == 0)
        #expect(ring.droppedLateFrames.load(ordering: .relaxed) == 0)
    }

    /// Muestras obsoletas muy por delante (tras buscar hacia atrás) se descartan.
    @Test func staleFutureAudioIsDiscarded() {
        let ring = filledRing(itemTime: 3.0)
        let (got, _) = readAligned(ring, desired: 1.0)
        #expect(got == 0 && ring.availableFrames == 0)
    }

    /// Relación host ↔ item publicada por el tap → tiempo deseado en el render.
    @Test func desiredTimeFollowsPublishedMapping() {
        let ring = AudioRingBuffer(channels: 2, sampleRate: 48_000)
        #expect(ring.desiredItemTime(hostTicks: 1) == nil)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticksPerSecond = 1e9 * Double(info.denom) / Double(info.numer)
        ring.publishMapping(rate: 1, itemAnchor: 2.0, hostAnchor: 100.0)
        ring.outputLatency = 0.01
        let desired = ring.desiredItemTime(hostTicks: UInt64(100.5 * ticksPerSecond))
        #expect(abs((desired ?? 0) - 2.51) < 1e-6)
        ring.publishMapping(rate: 0, itemAnchor: 2.0, hostAnchor: 100.0)
        #expect(ring.desiredItemTime(hostTicks: UInt64(100.5 * ticksPerSecond)) == nil)
        ring.alignmentEnabled.store(false, ordering: .relaxed)
        ring.publishMapping(rate: 1, itemAnchor: 2.0, hostAnchor: 100.0)
        #expect(ring.desiredItemTime(hostTicks: UInt64(100.5 * ticksPerSecond)) == nil)
    }

    /// Desajuste de frecuencia → silencio y aviso único (VideoInput lo emite como `.error`).
    @Test func mismatchIsReportedOnce() {
        let reports = LockedState<[Double]>([])
        let ring = AudioRingBuffer(channels: 2, sampleRate: 48_000) { rate in reports.withLock { $0.append(rate) } }
        ring.sourceFormat = planarFloat(44_100)
        withList(frames: 256) { ring.write($0, frames: 256) }
        withList(frames: 256) { ring.write($0, frames: 256) }
        #expect(reports.current == [44_100])
        #expect(ring.availableFrames == 0)
        let mismatch = ring.formatMismatch.load(ordering: .relaxed)
        #expect(mismatch)
    }
}
