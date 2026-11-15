import CoreAudio
import Foundation

/// Dispositivo de salida de audio del sistema (HAL): altavoces internos, jack, HDMI, USB…
///
/// `uid` es estable entre arranques y dispositivos re-enchufados (lo guarda Preferencias);
/// `deviceID` es el identificador vivo de esta sesión (lo usa el motor).
public struct AudioOutputDevice: Sendable, Equatable, Identifiable {
    public var deviceID: UInt32
    /// `kAudioDevicePropertyDeviceUID`: estable entre arranques; sirve para persistir la elección.
    public var uid: String
    public var name: String

    public var id: String { uid }

    public init(deviceID: UInt32, uid: String, name: String) {
        self.deviceID = deviceID
        self.uid = uid
        self.name = name
    }

    /// Todas las salidas disponibles ahora mismo (dispositivos con al menos un stream de salida),
    /// en el orden en que las lista el sistema. Vacío si no hay ninguna (CI sin audio).
    public static func available() -> [AudioOutputDevice] {
        HAL.allDeviceIDs().compactMap { id in
            guard HAL.firstOutputStream(id) != nil,
                  let uid = HAL.string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            return AudioOutputDevice(deviceID: id, uid: uid, name: HAL.name(id) ?? uid)
        }
    }

    /// Salida predeterminada del sistema en este momento (nil si no hay ninguna).
    public static func systemDefault() -> AudioOutputDevice? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard HAL.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                       scope: kAudioObjectPropertyScopeGlobal, into: &id),
              id != kAudioObjectUnknown,
              let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioOutputDevice(deviceID: id, uid: uid, name: HAL.name(id) ?? uid)
    }

    /// Dispositivo con ese UID, si sigue conectado.
    public static func find(uid: String) -> AudioOutputDevice? {
        available().first { $0.uid == uid }
    }
}

extension HAL {
    /// Todos los dispositivos de audio del sistema (entradas y salidas).
    static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }
}
