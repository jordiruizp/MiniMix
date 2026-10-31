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
/// tiempo de item debe sonar (`host + latencia de salida`). **Solo en
/// discontinuidades** (arranque, reanudación, vaciado, búsqueda o bucle) descarta
/// lo que llega tarde o retiene (silencio delante) lo que llega pronto; en régimen
/// es una cola pura (la cadena tap → nodo no deriva), así que no hay correcciones
/// ni clics. Así el audio coincide con el fotograma que `texture(for:)` muestra
/// desde el primer render. En pausa/preroll (rate 0) emite silencio sin consumir.
/// Sin tiempo de host (render offline) es una cola simple con latencia acotada.
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
    /// Al alinear, diferencias menores no se corrigen.
    static let tolerance = 0.002
    /// Salto de tiempo de item entre muestras consecutivas que se considera discontinuidad.
    static let continuityTolerance = 0.001
    /// Red de seguridad: error persistente mayor que esto durante `realignRenders` renders → realinear.
    static let realignThreshold = 0.05
    static let realignRenders = 100
    /// Muestras más adelantadas que esto respecto a lo deseado son obsoletas (búsqueda atrás).
    static let staleFuture = 0.5
    /// Pausa del transporte (la fija `VideoInput`): silencio sin consumir.
    let transportPaused = Atomic<Bool>(false)
    /// Diferencia entre el tiempo informado de un bloque y la continuación del anterior
    /// por encima de la cual se considera un salto real (búsqueda, bucle).
    static let producerJumpThreshold = 0.02
    /// Tiempo de item que continúa lo último escrito (solo productor).
    private var producerNextTime = Double.nan
    private var producerResetGeneration = 0
    /// Afinado del ancla: suma y número de diferencias (informado − continuo) desde el último ancla.
    private var anchorDiffs = 0.0
    private var anchorDiffCount = 0
    /// Bloques tras un ancla con los que se corrige su jitter (una sola vez).
    static let anchorRefineBlocks = 6
    private let timelineResetGeneration = Atomic<Int>(0)
    /// Renders seguidos esperando muestras con tiempo (solo consumidor).
    private var untimedRenders = 0
    /// Si en este número de renders no llega ninguna muestra con tiempo, se reproduce sin alinear.
    static let untimedGiveUpRenders = 50

    /// Arranque o búsqueda: la línea de tiempo se vuelve a anclar y el consumidor realinea.
    func resetTimeline() {
        timelineResetGeneration.add(1, ordering: .releasing)
        realignRequested.store(true, ordering: .relaxed)
    }
    /// Petición de realinear en el próximo render (arranque, búsqueda).
    let realignRequested = Atomic<Bool>(true)

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
    ///
    /// Excepción documentada a «nada bloqueante en audio»: `CMSyncGetRelativeRateAndAnchorTime`
    /// puede tomar un cerrojo interno breve de CoreMedia. Se llama en el hilo del tap
    /// (el de proceso de audio de AVPlayer, que ya hace E/S y decodificación), nunca
    /// en el render del motor de E, que solo lee atómicos.
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
        // El `timeRangeOut` del tap tiene jitter de varios ms por bloque (p. ej. ±4 ms con
        // AAC) aunque las muestras sean contiguas: se mantiene la línea de tiempo
        // continua y solo se acepta el tiempo informado en un salto real (búsqueda, bucle).
        // Tras arrancar o buscar (`resetTimeline`) se vuelve a anclar con el primer
        // tiempo informado. Los bloques sin tiempo y sin ancla quedan sin tiempo (NaN):
        // el consumidor no los puede situar y los salta al alinear.
        let resetGeneration = timelineResetGeneration.load(ordering: .acquiring)
        if resetGeneration != producerResetGeneration {
            producerResetGeneration = resetGeneration
            producerNextTime = .nan
        }
        var start = itemTime ?? producerNextTime
        if !start.isNaN, !producerNextTime.isNaN, abs(start - producerNextTime) < Self.producerJumpThreshold {
            start = producerNextTime + anchorCorrection(reported: itemTime)
        } else {
            // Ancla nueva (arranque o salto real): se afina con la media de los siguientes bloques.
            anchorDiffs = 0
            anchorDiffCount = 0
        }
        producerNextTime = start + Double(count) / sampleRate
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

    /// El tiempo informado de un bloque tiene jitter; el ancla (primer bloque tras un
    /// arranque o salto) lo hereda. Tras `anchorRefineBlocks` bloques se desplaza la
    /// línea de tiempo una sola vez por la media de las diferencias, si supera 1 ms:
    /// el consumidor lo ve como una pequeña discontinuidad y realinea una vez (en el
    /// primer medio segundo), y después ya no hay correcciones.
    private func anchorCorrection(reported: Double?) -> Double {
        guard let reported, anchorDiffCount < Self.anchorRefineBlocks else { return 0 }
        anchorDiffs += reported - producerNextTime
        anchorDiffCount += 1
        guard anchorDiffCount == Self.anchorRefineBlocks else { return 0 }
        let mean = anchorDiffs / Double(anchorDiffCount)
        return abs(mean) > 0.001 ? mean : 0
    }

    // MARK: Consumidor (render)

    private struct TimeMapping {
        let rate: Double
        let item: Double
        let host: Double
    }

    /// Qué hacer en un render.
    enum RenderClock {
        /// Sin tiempo de host (render offline): cola simple.
        case none
        /// Reproduciendo: tiempo de item que debe sonar con el primer fotograma.
        case playing(desiredItemTime: Double)
        /// Pausa / preroll (rate 0): silencio sin consumir.
        case paused
    }

    // Estado solo del consumidor (hilo de render): no necesita atómicos.
    private var lastMapping: TimeMapping?
    private var needsAlign = true
    private var expectedNextTime = Double.nan
    private var offAlignRenders = 0

    /// Relación host ↔ item publicada; si el seqlock no se puede leer ahora, la
    /// última válida (solo cambia en arranques, pausas y saltos).
    private func mapping() -> TimeMapping? {
        for _ in 0..<4 {
            let before = mappingSequence.load(ordering: .acquiring)
            guard before > 0, before & 1 == 0 else { continue }
            let rate = Double(bitPattern: mappingRate.load(ordering: .relaxed))
            let item = Double(bitPattern: mappingItemAnchor.load(ordering: .relaxed))
            let host = Double(bitPattern: mappingHostAnchor.load(ordering: .relaxed))
            atomicMemoryFence(ordering: .acquiring)
            if mappingSequence.load(ordering: .relaxed) == before {
                lastMapping = TimeMapping(rate: rate, item: item, host: host)
                break
            }
        }
        return lastMapping
    }

    /// Reloj del render cuyo tiempo de host (ticks de `mach_absolute_time`) es
    /// `hostTicks` (nil = sin tiempo de host).
    func renderClock(hostTicks: UInt64?) -> RenderClock {
        guard alignmentEnabled.load(ordering: .relaxed), let hostTicks else { return .none }
        if transportPaused.load(ordering: .relaxed) { return .paused }
        guard let map = mapping() else { return .none }
        guard map.rate > 0 else { return .paused }
        let host = Double(hostTicks) * hostTicksToSeconds + outputLatency + extraOffset
        return .playing(desiredItemTime: map.item + map.rate * (host - map.host))
    }

    /// Render del nodo: índice de escritura primero (acquire), después el reloj.
    @discardableResult
    func render(into list: UnsafeMutableAudioBufferListPointer, frames: Int, hostTicks: UInt64?) -> Int {
        let write = writeIndex.load(ordering: .acquiring)
        return read(into: list, frames: frames, clock: renderClock(hostTicks: hostTicks), write: write)
    }

    /// Lee `frames` muestras planas en `list` (formato estándar del nodo).
    ///
    /// Con reloj de reproducción **solo alinea en discontinuidades** (primer render
    /// tras arrancar, pausa o vaciado; salto de tiempo de item por búsqueda o bucle;
    /// petición explícita; o error persistente > `realignThreshold`). Entre medias es
    /// una cola pura: no quita ni inserta muestras, así que no hay clics en régimen.
    @discardableResult
    func read(into list: UnsafeMutableAudioBufferListPointer, frames: Int, clock: RenderClock, write: Int? = nil) -> Int {
        let write = write ?? writeIndex.load(ordering: .acquiring)
        var read = readIndex.load(ordering: .relaxed)
        var pad = 0
        switch clock {
        case .none:
            if write - read > maxLatencyFrames + frames { read = write - maxLatencyFrames }
        case .paused:
            needsAlign = true
            Self.silence(list, from: 0, frames: frames, channels: channels)
            return 0
        case .playing(let desired):
            if realignRequested.exchange(false, ordering: .relaxed) { needsAlign = true }
            guard read < write else {
                needsAlign = true // vaciado: al volver el audio, realinear
                Self.silence(list, from: 0, frames: frames, channels: channels)
                return 0
            }
            checkContinuity(head: times[read & mask], desired: desired)
            if needsAlign { (read, pad) = align(read: read, write: write, frames: frames, desired: desired) }
        }
        let count = max(0, min(frames - pad, write - read))
        copyOut(list, from: read, count: count, pad: pad, frames: frames)
        if count > 0 {
            let first = times[read & mask]
            let last = times[(read + count - 1) & mask]
            // Discontinuidad dentro de lo copiado (bucle, búsqueda): realinear en el siguiente.
            if case .playing = clock, abs((last - first) - Double(count - 1) / sampleRate) > Self.continuityTolerance {
                needsAlign = true
            }
            expectedNextTime = last + 1 / sampleRate
        }
        readIndex.store(read + count, ordering: .releasing)
        return count
    }

    /// Marca realineación si la cabeza no continúa lo último leído o si el error
    /// respecto al reloj supera el umbral durante `realignRenders` renders seguidos.
    private func checkContinuity(head: Double, desired: Double) {
        guard !needsAlign, !head.isNaN else { return }
        if !expectedNextTime.isNaN, abs(head - expectedNextTime) > Self.continuityTolerance {
            needsAlign = true
            return
        }
        if abs(head - desired) > Self.realignThreshold {
            offAlignRenders += 1
            if offAlignRenders >= Self.realignRenders { needsAlign = true }
        } else {
            offAlignRenders = 0
        }
    }

    /// Busca la primera muestra que toca sonar: descarta, muestra a muestra, las
    /// atrasadas y las obsoletas muy por delante (tras buscar hacia atrás), y se para
    /// en la primera válida, sin pasarse. Si llega pronto, antepone silencio.
    private func align(read: Int, write: Int, frames: Int, desired: Double) -> (read: Int, pad: Int) {
        var index = read
        // Muestras sin tiempo (antes del primer `timeRangeOut` válido): no se pueden
        // situar. Se saltan si detrás ya hay muestras con tiempo; si no, se espera
        // (silencio) un máximo de `untimedGiveUpRenders` renders y después se reproduce sin alinear.
        if times[read & mask].isNaN {
            if times[(write - 1) & mask].isNaN {
                untimedRenders += 1
                if untimedRenders > Self.untimedGiveUpRenders {
                    needsAlign = false
                    return (read, 0)
                }
                return (read, frames)
            }
            while index < write, times[index & mask].isNaN { index += 1 }
        }
        untimedRenders = 0
        while index < write {
            let time = times[index & mask]
            // Tarde: hasta la muestra exacta (media muestra); obsoleta: muy por delante.
            if time < desired - 0.5 / sampleRate || time - desired > Self.staleFuture {
                index += 1
            } else {
                break
            }
        }
        droppedLateFrames.add(index - read, ordering: .relaxed)
        offAlignRenders = 0
        guard index < write else { return (index, frames) } // sigue pendiente de alinear
        let early = times[index & mask] - desired
        var pad = 0
        if early > Self.tolerance { pad = min(frames, Int((early * sampleRate).rounded())) }
        paddedEarlyFrames.add(pad, ordering: .relaxed)
        // Si el audio empieza más allá de este render, se vuelve a calcular en el siguiente.
        needsAlign = pad == frames
        expectedNextTime = times[index & mask]
        return (index, pad)
    }

    private func copyOut(_ list: UnsafeMutableAudioBufferListPointer, from read: Int, count: Int, pad: Int, frames: Int) {
        for ch in 0..<min(channels, list.count) {
            guard let out = list[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            if pad > 0 { out.update(repeating: 0, count: pad) }
            let plane = storage + ch * capacity
            for i in 0..<count { out[pad + i] = plane[(read + i) & mask] }
            let filled = pad + count
            if filled < frames { (out + filled).update(repeating: 0, count: frames - filled) }
        }
    }

    private static func silence(_ list: UnsafeMutableAudioBufferListPointer, from start: Int, frames: Int, channels: Int) {
        for buffer in list {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            (out + start).update(repeating: 0, count: frames - start)
        }
    }
}
