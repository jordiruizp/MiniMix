import AudioToolbox
import CoreMedia
import Darwin
import Synchronization

/// Cola circular SPSC sin cerrojos de muestras Float planas, **marcadas con su
/// tiempo de item** para alinear el audio con el vídeo.
///
/// Productor: el tap de `AVPlayer` (hilo de audio del reproductor). Cada muestra
/// lleva el tiempo de item que le asigna `MTAudioProcessingTapGetSourceAudio`
/// (`timeRangeOut`). El tap publica además la relación host ↔ item del `timebase`
/// del item (`publishMapping`).
///
/// Consumidor: el bloque de render de `AVAudioSourceNode` (hilo de tiempo real).
/// Con la marca de tiempo de host del render y la relación publicada calcula qué
/// tiempo de item debe sonar (`host + latencia de salida`) y **descarta** lo que
/// llega tarde o **retiene** (silencio delante) lo que llega pronto. Así el audio
/// coincide con el fotograma que `texture(for:)` muestra en ese instante, también
/// en el arranque (cuando el tap recibe el audio cientos de ms después de que el
/// reloj del item ya corre). Sin relación publicada o sin tiempo de host (render
/// offline) se comporta como una cola simple con latencia acotada.
///
/// `@unchecked Sendable` justificado: el almacenamiento es memoria cruda
/// compartida por exactamente un productor y un consumidor, sincronizados con
/// índices atómicos (release/acquire); ningún hueco se lee y escribe a la vez. La
/// relación host ↔ item se publica con un seqlock de atómicos.
final class AudioRingBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    let maxLatencyFrames: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Tiempo de item (s) de cada muestra; NaN = desconocido.
    private let times: UnsafeMutablePointer<Double>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// Formato que entrega el tap. Lo escribe el callback `prepare` y lo lee
    /// `process`: MediaToolbox invoca ambos en serie en el hilo de proceso del tap y
    /// `prepare` siempre ocurre antes del primer `process` (y tras `unprepare`, antes
    /// de cualquier `process` con el formato nuevo), así que no hay carrera. El
    /// consumidor (render del nodo) nunca lo lee.
    var sourceFormat = AudioStreamBasicDescription()
    /// Frecuencia que espera el nodo; si el tap entrega otra, se emite silencio.
    let sampleRate: Double
    let formatMismatch = Atomic<Bool>(false)
    /// Se invoca una sola vez, desde el hilo del tap, con la frecuencia recibida.
    private let onFormatMismatch: (@Sendable (Double) -> Void)?

    // Relación item = itemAnchor + rate · (host − hostAnchor), publicada con seqlock.
    private let mappingSequence = Atomic<Int>(0)
    private let mappingRate = Atomic<UInt64>(0)
    private let mappingItemAnchor = Atomic<UInt64>(0)
    private let mappingHostAnchor = Atomic<UInt64>(0)
    /// Latencia de presentación de la salida del motor (s), la fija `VideoInput`.
    private let outputLatencyBits = Atomic<UInt64>(0)
    /// Desfase adicional (s) que se suma al tiempo deseado (calibración; 0 por defecto).
    private let extraOffsetBits = Atomic<UInt64>(0)
    /// Alineación activa (se puede desactivar para medir el comportamiento previo).
    let alignmentEnabled = Atomic<Bool>(true)
    /// Muestras descartadas por llegar tarde / silencio insertado por llegar pronto (diagnóstico).
    let droppedLateFrames = Atomic<Int>(0)
    let paddedEarlyFrames = Atomic<Int>(0)

    private let hostTicksToSeconds: Double
    /// Timebase del item (retenido), fijado antes de reproducir; lo lee el tap.
    private let timebasePointer = Atomic<UnsafeMutableRawPointer?>(nil)
    /// Por debajo de esta diferencia no se corrige (evita micro-cortes por jitter).
    static let tolerance = 0.002

    init(channels: Int, sampleRate: Double, capacityFrames: Int = 1 << 15, maxLatencyFrames: Int = 4096,
         onFormatMismatch: (@Sendable (Double) -> Void)? = nil) {
        self.onFormatMismatch = onFormatMismatch
        precondition(capacityFrames > 0 && capacityFrames & (capacityFrames - 1) == 0, "potencia de 2")
        self.channels = max(1, channels)
        self.capacity = capacityFrames
        self.mask = capacityFrames - 1
        self.maxLatencyFrames = maxLatencyFrames
        self.sampleRate = sampleRate
        storage = .allocate(capacity: self.channels * capacityFrames)
        storage.initialize(repeating: 0, count: self.channels * capacityFrames)
        times = .allocate(capacity: capacityFrames)
        times.initialize(repeating: .nan, count: capacityFrames)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        hostTicksToSeconds = Double(info.numer) / Double(info.denom) / 1e9
    }

    deinit {
        storage.deallocate()
        times.deallocate()
        if let old = timebasePointer.exchange(nil, ordering: .acquiringAndReleasing) {
            Unmanaged<CMTimebase>.fromOpaque(old).release()
        }
    }

    /// Fija el timebase del item (antes de reproducir). El tap lo usa para publicar
    /// la relación host ↔ item.
    func setTimebase(_ timebase: CMTimebase?) {
        let new = timebase.map { Unmanaged.passRetained($0).toOpaque() }
        if let old = timebasePointer.exchange(new, ordering: .acquiringAndReleasing) {
            Unmanaged<CMTimebase>.fromOpaque(old).release()
        }
    }

    /// Hilo del tap: lee la relación actual del timebase con el reloj del host y la publica.
    func refreshMappingFromTimebase() {
        guard let pointer = timebasePointer.load(ordering: .acquiring) else { return }
        let timebase = Unmanaged<CMTimebase>.fromOpaque(pointer).takeUnretainedValue()
        var rate: Float64 = 0
        var itemAnchor = CMTime.invalid
        var hostAnchor = CMTime.invalid
        let status = CMSyncGetRelativeRateAndAnchorTime(
            timebase, relativeTo: CMClockGetHostTimeClock(),
            relativeRateOut: &rate, anchorTimeOut: &itemAnchor, relativeToAnchorTimeOut: &hostAnchor)
        guard status == noErr, itemAnchor.isValid, hostAnchor.isValid else { return }
        publishMapping(rate: rate, itemAnchor: itemAnchor.seconds, hostAnchor: hostAnchor.seconds)
    }

    var availableFrames: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }

    var outputLatency: Double {
        get { Double(bitPattern: outputLatencyBits.load(ordering: .relaxed)) }
        set { outputLatencyBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var extraOffset: Double {
        get { Double(bitPattern: extraOffsetBits.load(ordering: .relaxed)) }
        set { extraOffsetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    // MARK: Productor (tap)

    /// Publica la relación host ↔ item del timebase del item (hilo del tap).
    func publishMapping(rate: Double, itemAnchor: Double, hostAnchor: Double) {
        let sequence = mappingSequence.load(ordering: .relaxed)
        mappingSequence.store(sequence + 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        mappingRate.store(rate.bitPattern, ordering: .relaxed)
        mappingItemAnchor.store(itemAnchor.bitPattern, ordering: .relaxed)
        mappingHostAnchor.store(hostAnchor.bitPattern, ordering: .relaxed)
        mappingSequence.store(sequence + 2, ordering: .releasing)
    }

    /// Escribe `frames` muestras Float32 del formato del tap (planar o entrelazado);
    /// `itemTime` es el tiempo de item de la primera (nil = desconocido).
    func write(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, itemTime: Double? = nil) {
        let format = sourceFormat
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return }
        if abs(format.mSampleRate - sampleRate) > 0.5 {
            if !formatMismatch.exchange(true, ordering: .relaxed) { onFormatMismatch?(format.mSampleRate) }
            return
        }
        let srcChannels = max(1, Int(format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let count = min(frames, capacity - (write - read))
        guard count > 0 else { return }
        copyIn(list, count: count, at: write, srcChannels: srcChannels, interleaved: interleaved)
        let start = itemTime ?? .nan
        for i in 0..<count { times[(write + i) & mask] = start + Double(i) / sampleRate }
        writeIndex.store(write + count, ordering: .releasing)
    }

    private func copyIn(_ list: UnsafeMutableAudioBufferListPointer, count: Int, at write: Int,
                        srcChannels: Int, interleaved: Bool) {
        for ch in 0..<channels {
            let src = min(ch, srcChannels - 1)
            let plane = storage + ch * capacity
            if interleaved {
                guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<count { plane[(write + i) & mask] = data[i * srcChannels + src] }
            } else {
                guard src < list.count, let data = list[src].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<count { plane[(write + i) & mask] = data[i] }
            }
        }
    }

    // MARK: Consumidor (render)

    private struct TimeMapping {
        let rate: Double
        let item: Double
        let host: Double
    }

    /// Relación host ↔ item publicada, o nil si no hay (o se está escribiendo).
    private func mapping() -> TimeMapping? {
        for _ in 0..<4 {
            let before = mappingSequence.load(ordering: .acquiring)
            guard before > 0, before & 1 == 0 else { continue }
            let rate = Double(bitPattern: mappingRate.load(ordering: .relaxed))
            let item = Double(bitPattern: mappingItemAnchor.load(ordering: .relaxed))
            let host = Double(bitPattern: mappingHostAnchor.load(ordering: .relaxed))
            atomicMemoryFence(ordering: .acquiring)
            if mappingSequence.load(ordering: .relaxed) == before { return TimeMapping(rate: rate, item: item, host: host) }
        }
        return nil
    }

    /// Tiempo de item que debe sonar con el primer fotograma de un render cuyo
    /// tiempo de host (ticks de `mach_absolute_time`) es `hostTicks`.
    func desiredItemTime(hostTicks: UInt64) -> Double? {
        guard alignmentEnabled.load(ordering: .relaxed), let map = mapping(), map.rate > 0 else { return nil }
        let host = Double(hostTicks) * hostTicksToSeconds + outputLatency + extraOffset
        return map.item + map.rate * (host - map.host)
    }

    /// true si la relación publicada indica pausa (rate 0): el render emite silencio
    /// sin consumir.
    func isPausedMapping() -> Bool {
        guard alignmentEnabled.load(ordering: .relaxed), let map = mapping() else { return false }
        return map.rate == 0
    }

    /// Lee `frames` muestras planas en `list` (formato estándar del nodo). Con
    /// `desiredItemTime` alinea por tiempo de item; sin él, cola simple. Rellena con
    /// silencio lo que falte. Devuelve las muestras reales leídas.
    @discardableResult
    func read(into list: UnsafeMutableAudioBufferListPointer, frames: Int, desiredItemTime: Double? = nil) -> Int {
        let write = writeIndex.load(ordering: .acquiring)
        var read = readIndex.load(ordering: .relaxed)
        var pad = 0
        if let desired = desiredItemTime {
            (read, pad) = align(read: read, write: write, frames: frames, desired: desired)
        } else if write - read > maxLatencyFrames + frames {
            read = write - maxLatencyFrames
        }
        let count = min(frames - pad, write - read)
        for ch in 0..<min(channels, list.count) {
            guard let out = list[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            if pad > 0 { out.update(repeating: 0, count: pad) }
            let plane = storage + ch * capacity
            for i in 0..<max(count, 0) { out[pad + i] = plane[(read + i) & mask] }
            let filled = pad + max(count, 0)
            if filled < frames { (out + filled).update(repeating: 0, count: frames - filled) }
        }
        readIndex.store(read + max(count, 0), ordering: .releasing)
        return max(count, 0)
    }

    /// Ajusta el índice de lectura al tiempo deseado: descarta lo que llega tarde y
    /// calcula cuánto silencio anteponer si llega pronto. O(1) salvo un ajuste fino.
    private func align(read: Int, write: Int, frames: Int, desired: Double) -> (read: Int, pad: Int) {
        var read = read
        guard read < write else { return (read, frames) }
        var head = times[read & mask]
        guard !head.isNaN else { return (read, 0) }
        // Muestras viejas muy por delante (p. ej. tras buscar hacia atrás): obsoletas.
        if head - desired > 0.5 {
            droppedLateFrames.add(write - read, ordering: .relaxed)
            return (write, frames)
        }
        let late = desired - head
        if late > Self.tolerance {
            let skip = min(Int(late * sampleRate), write - read)
            droppedLateFrames.add(skip, ordering: .relaxed)
            read += skip
            // Ajuste fino por discontinuidades (bucle, búsqueda) dentro de lo saltado.
            while read < write, desired - times[read & mask] > Self.tolerance { read += 1 }
            guard read < write else { return (read, frames) }
            head = times[read & mask]
        }
        let early = head - desired
        if early > Self.tolerance {
            let pad = min(frames, Int(early * sampleRate))
            paddedEarlyFrames.add(pad, ordering: .relaxed)
            return (read, pad)
        }
        return (read, 0)
    }
}
