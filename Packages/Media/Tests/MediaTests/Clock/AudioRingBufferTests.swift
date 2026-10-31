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
            #expect(ring.read(into: out, frames: 256, clock: .none) == 256)
            #expect(out[0].mData!.assumingMemoryBound(to: Float.self)[100] == 0.5)
        }
    }

    // MARK: Alineación por tiempo de item

    private func makeRing() -> AudioRingBuffer {
        let ring = AudioRingBuffer(channels: 2, sampleRate: 48_000)
        ring.sourceFormat = planarFloat(48_000)
        return ring
    }

    private func append(_ ring: AudioRingBuffer, itemTime: Double, frames: Int = 4_800) {
        withList(frames: frames) { ring.write($0, frames: frames, itemTime: itemTime) }
    }

    /// Lee y devuelve (muestras reales, silencio inicial).
    @discardableResult
    private func readAt(_ ring: AudioRingBuffer, _ clock: AudioRingBuffer.RenderClock, frames: Int = 480) -> (Int, Int) {
        var result = (0, 0)
        withList(frames: frames) { out in
            let got = ring.read(into: out, frames: frames, clock: clock)
            let data = out[0].mData!.assumingMemoryBound(to: Float.self)
            result = (got, (0..<frames).prefix { data[$0] == 0 }.count)
        }
        return result
    }

    private func dropped(_ ring: AudioRingBuffer) -> Int { ring.droppedLateFrames.load(ordering: .relaxed) }
    private func padded(_ ring: AudioRingBuffer) -> Int { ring.paddedEarlyFrames.load(ordering: .relaxed) }

    /// Arranque con audio tarde: se descarta exactamente lo atrasado (I3: sin pasarse).
    @Test func lateAudioIsDroppedExactly() {
        let ring = makeRing()
        append(ring, itemTime: 1.0) // 1,0…1,1 s
        let (got, silence) = readAt(ring, .playing(desiredItemTime: 1.05))
        #expect(got == 480 && silence == 0)
        #expect(dropped(ring) == 2_400)
    }

    /// Arranque con audio pronto: se retiene (silencio delante) hasta su instante.
    @Test func earlyAudioIsHeld() {
        let ring = makeRing()
        append(ring, itemTime: 1.0)
        let (got, silence) = readAt(ring, .playing(desiredItemTime: 0.995)) // 5 ms antes
        #expect(silence == 240 && got == 240)
    }

    /// B1: en régimen es una cola pura. Aunque el reloj se desvíe unos ms (modelo vs
    /// consumo), no se quita ni se inserta nada: sin clics.
    @Test func steadyStateNeverCorrects() {
        let ring = makeRing()
        append(ring, itemTime: 1.0, frames: 32_000)
        readAt(ring, .playing(desiredItemTime: 1.0))
        let (d0, p0) = (dropped(ring), padded(ring))
        for n in 1..<60 {
            // El reloj deriva +1 ms por render (hasta +59 ms, por encima de la
            // tolerancia de alineación pero sin persistir lo bastante para la red de seguridad).
            let desired = 1.0 + Double(n) * 0.01 + Double(n) * 0.001
            let (got, silence) = readAt(ring, .playing(desiredItemTime: desired))
            #expect(got == 480 && silence == 0)
        }
        #expect(dropped(ring) == d0 && padded(ring) == p0)
    }

    /// Red de seguridad: error > 50 ms persistente (100 renders) → realinear una vez.
    @Test func persistentLargeErrorRealignsOnce() {
        let ring = makeRing()
        append(ring, itemTime: 1.0, frames: 32_000)
        readAt(ring, .playing(desiredItemTime: 1.0))
        for n in 1...30 { readAt(ring, .playing(desiredItemTime: 1.0 + Double(n) * 0.01 + 0.06), frames: 480) }
        #expect(dropped(ring) == 0)
        for n in 31...130 { readAt(ring, .playing(desiredItemTime: 1.0 + Double(n) * 0.01 + 0.06), frames: 1) }
        #expect(dropped(ring) > 0)
    }

    /// Bucle/búsqueda (I4): el salto de tiempo de item dispara una realineación, y
    /// solo se descarta hasta la discontinuidad, no el audio nuevo.
    @Test func discontinuityRealignsWithoutDiscardingNewAudio() {
        let ring = makeRing()
        append(ring, itemTime: 3.0, frames: 480)  // final de la vuelta anterior
        append(ring, itemTime: 0.0, frames: 4_800) // vuelta nueva desde 0
        let (got, _) = readAt(ring, .playing(desiredItemTime: 0.0))
        #expect(got == 480)
        #expect(dropped(ring) == 480)
        #expect(ring.availableFrames == 4_800 - 480)
    }

    @Test func discontinuityInsideCopiedBlockTriggersRealign() {
        let ring = makeRing()
        append(ring, itemTime: 1.0, frames: 240)
        append(ring, itemTime: 5.0, frames: 4_800) // búsqueda adelante
        readAt(ring, .playing(desiredItemTime: 1.0))   // copia 240 + 240 del salto
        let (got, _) = readAt(ring, .playing(desiredItemTime: 5.01))
        #expect(got == 480)
        #expect(dropped(ring) == 480 - 240) // realinea a 5,01: descarta lo anterior a 5,01
    }

    /// El jitter del `timeRangeOut` del tap (±4 ms por bloque) no rompe la continuidad;
    /// un salto real (> 20 ms) sí.
    @Test func producerSmoothsTimestampJitter() {
        let ring = makeRing()
        append(ring, itemTime: 1.0, frames: 4_096)
        append(ring, itemTime: 1.0 + 4_096 / 48_000 - 0.004, frames: 4_096) // −4 ms de jitter
        append(ring, itemTime: 1.0 + 8_192 / 48_000 + 0.0077, frames: 4_096) // +7,7 ms
        readAt(ring, .playing(desiredItemTime: 1.0), frames: 4_096)
        for n in 1..<3 { readAt(ring, .playing(desiredItemTime: 1.0 + Double(n) * 4_096 / 48_000), frames: 4_096) }
        #expect(dropped(ring) == 0 && padded(ring) == 0)
        append(ring, itemTime: 7.0, frames: 4_096) // búsqueda
        readAt(ring, .playing(desiredItemTime: 7.01), frames: 480)
        #expect(dropped(ring) == 480)
    }

    /// I1: en pausa (rate 0) silencio sin consumir; al reanudar, realinea.
    @Test func pausedEmitsSilenceWithoutConsuming() {
        let ring = makeRing()
        append(ring, itemTime: 1.0)
        let (got, silence) = readAt(ring, .paused)
        #expect(got == 0 && silence == 480)
        #expect(ring.availableFrames == 4_800)
        ring.transportPaused.store(true, ordering: .relaxed)
        ring.publishMapping(rate: 1, itemAnchor: 1, hostAnchor: 0)
        if case .paused = ring.renderClock(hostTicks: 1) {} else { Issue.record("debería estar en pausa") }
        ring.transportPaused.store(false, ordering: .relaxed)
        ring.publishMapping(rate: 0, itemAnchor: 1, hostAnchor: 0)
        if case .paused = ring.renderClock(hostTicks: 1) {} else { Issue.record("rate 0 debería ser pausa") }
    }

    /// Al alinear (solo en discontinuidades) se va a la muestra exacta: 1 ms tarde = 48 muestras.
    @Test func alignsToTheExactSample() {
        let ring = makeRing()
        append(ring, itemTime: 1.0)
        let (got, silence) = readAt(ring, .playing(desiredItemTime: 1.001))
        #expect(got == 480 && silence == 0)
        #expect(dropped(ring) == 48)
    }

    @Test func staleFutureAudioIsDiscarded() {
        let ring = makeRing()
        append(ring, itemTime: 3.0)
        let (got, _) = readAt(ring, .playing(desiredItemTime: 1.0))
        #expect(got == 0 && ring.availableFrames == 0)
    }

    /// Relación host ↔ item publicada por el tap → tiempo deseado en el render.
    @Test func renderClockFollowsPublishedMapping() {
        let ring = AudioRingBuffer(channels: 2, sampleRate: 48_000)
        if case .none = ring.renderClock(hostTicks: 1) {} else { Issue.record("sin relación: cola simple") }
        if case .none = ring.renderClock(hostTicks: nil) {} else { Issue.record("sin host: cola simple") }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticksPerSecond = 1e9 * Double(info.denom) / Double(info.numer)
        ring.publishMapping(rate: 1, itemAnchor: 2.0, hostAnchor: 100.0)
        ring.outputLatency = 0.01
        if case .playing(let desired) = ring.renderClock(hostTicks: UInt64(100.5 * ticksPerSecond)) {
            #expect(abs(desired - 2.51) < 1e-6)
        } else {
            Issue.record("debería reproducir")
        }
        ring.alignmentEnabled.store(false, ordering: .relaxed)
        if case .none = ring.renderClock(hostTicks: 1) {} else { Issue.record("alineación desactivada") }
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
