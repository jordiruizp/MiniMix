import AudioToolbox
import Synchronization

/// Cola circular SPSC sin cerrojos de muestras Float planas.
///
/// Productor: el tap de `AVPlayer` (hilo de audio del reproductor).
/// Consumidor: el bloque de render de `AVAudioSourceNode` (hilo de tiempo real).
/// Si el consumidor acumula más de `maxLatencyFrames` de retraso, descarta lo más
/// antiguo para que la latencia de audio quede acotada (p. ej. si el motor
/// arranca tarde). Si el productor encuentra la cola llena, descarta lo nuevo.
///
/// `@unchecked Sendable` justificado: el almacenamiento es memoria cruda
/// compartida por exactamente un productor y un consumidor, sincronizados con
/// índices atómicos (release/acquire); ningún hueco se lee y escribe a la vez.
final class AudioRingBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    let maxLatencyFrames: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
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
    }

    deinit { storage.deallocate() }

    var availableFrames: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }

    /// Escribe `frames` muestras Float32 del formato del tap (planar o entrelazado).
    func write(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
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
        writeIndex.store(write + count, ordering: .releasing)
    }

    /// Lee `frames` muestras planas en `list` (formato estándar del nodo). Rellena
    /// con silencio lo que falte. Devuelve las muestras reales leídas.
    @discardableResult
    func read(into list: UnsafeMutableAudioBufferListPointer, frames: Int) -> Int {
        let write = writeIndex.load(ordering: .acquiring)
        var read = readIndex.load(ordering: .relaxed)
        if write - read > maxLatencyFrames + frames { read = write - maxLatencyFrames }
        let count = min(frames, write - read)
        for ch in 0..<min(channels, list.count) {
            guard let out = list[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let plane = storage + ch * capacity
            for i in 0..<count { out[i] = plane[(read + i) & mask] }
            if count < frames { (out + count).update(repeating: 0, count: frames - count) }
        }
        readIndex.store(read + count, ordering: .releasing)
        return count
    }
}
