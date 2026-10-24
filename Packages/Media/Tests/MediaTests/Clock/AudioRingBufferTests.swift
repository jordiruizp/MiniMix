import AudioToolbox
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
