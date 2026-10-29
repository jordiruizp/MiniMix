import CoreAudio
import Foundation

/// Latencia de un dispositivo de salida de Core Audio (HAL), en muestras del dispositivo.
///
/// Desde el instante del ciclo de render (marca de tiempo de salida del búfer, la que ven los
/// *taps* del motor) hasta que el sonido sale por el altavoz pasan
/// `device + stream + safetyOffset` muestras: `presentationSeconds`. El búfer de E/S
/// (`bufferFrames`) no suma a eso; es el adelanto con el que se renderiza respecto a esa marca.
/// En Bluetooth y AirPlay `device`/`stream` llegan a 100–250 ms.
public struct OutputLatency: Sendable, Equatable {
    public var deviceID: UInt32
    public var deviceName: String
    public var sampleRate: Double
    /// `kAudioDevicePropertyLatency` (ámbito de salida).
    public var deviceFrames: UInt32
    /// `kAudioStreamPropertyLatency` del primer stream de salida.
    public var streamFrames: UInt32
    /// `kAudioDevicePropertySafetyOffset` (ámbito de salida).
    public var safetyOffsetFrames: UInt32
    /// `kAudioDevicePropertyBufferFrameSize`.
    public var bufferFrames: UInt32

    public init(deviceID: UInt32, deviceName: String, sampleRate: Double, deviceFrames: UInt32,
                streamFrames: UInt32, safetyOffsetFrames: UInt32, bufferFrames: UInt32) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.sampleRate = sampleRate
        self.deviceFrames = deviceFrames
        self.streamFrames = streamFrames
        self.safetyOffsetFrames = safetyOffsetFrames
        self.bufferFrames = bufferFrames
    }

    /// Render → altavoz (s).
    public var presentationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(UInt64(deviceFrames) + UInt64(streamFrames) + UInt64(safetyOffsetFrames)) / sampleRate
    }

    /// Duración del búfer de E/S (s).
    public var bufferSeconds: Double { sampleRate > 0 ? Double(bufferFrames) / sampleRate : 0 }

    /// Dispositivo de salida por defecto del sistema (nil si no hay ninguno).
    public static func defaultOutputDevice() -> OutputLatency? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard HAL.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                       scope: kAudioObjectPropertyScopeGlobal, into: &id),
              id != kAudioObjectUnknown else { return nil }
        return device(id)
    }

    /// Latencias de `deviceID` (nil si no existe o no tiene salida).
    public static func device(_ deviceID: UInt32) -> OutputLatency? {
        let output = kAudioObjectPropertyScopeOutput
        var rate: Float64 = 0
        guard deviceID != kAudioObjectUnknown,
              HAL.read(deviceID, kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal, into: &rate),
              rate > 0 else { return nil }
        var latency: UInt32 = 0
        var safety: UInt32 = 0
        var buffer: UInt32 = 0
        _ = HAL.read(deviceID, kAudioDevicePropertyLatency, scope: output, into: &latency)
        _ = HAL.read(deviceID, kAudioDevicePropertySafetyOffset, scope: output, into: &safety)
        _ = HAL.read(deviceID, kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal, into: &buffer)
        var streamLatency: UInt32 = 0
        if let stream = HAL.firstOutputStream(deviceID) {
            _ = HAL.read(stream, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal, into: &streamLatency)
        }
        return OutputLatency(deviceID: deviceID, deviceName: HAL.name(deviceID) ?? "?", sampleRate: rate,
                             deviceFrames: latency, streamFrames: streamLatency,
                             safetyOffsetFrames: safety, bufferFrames: buffer)
    }
}

/// Lecturas de propiedades del HAL que devuelven `OSStatus` (nunca lanzan).
private enum HAL {
    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                         scope: AudioObjectPropertyScope, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr
        }
    }

    static func firstOutputStream(_ device: AudioObjectID) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    static func name(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
