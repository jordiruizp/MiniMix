import Foundation
import Synchronization
import Testing
@testable import Audio

/// Selección de la salida física (Preferencias › Audio). En CI puede no haber dispositivos:
/// los tests que los necesitan salen limpiamente.
@Suite struct OutputDeviceTests {
    @Test func availableOutputsHaveStableIdentity() {
        let devices = AudioOutputDevice.available()
        print("[AV] salidas: \(devices.map { "\($0.name) [\($0.uid)]" }.joined(separator: ", "))")
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
        }
        #expect(Set(devices.map(\.uid)).count == devices.count, "UIDs únicos")
    }

    @Test func systemDefaultIsListedAndFindable() {
        guard let fallback = AudioOutputDevice.systemDefault() else {
            print("[AV] sin salida predeterminada (CI)")
            return
        }
        let devices = AudioOutputDevice.available()
        #expect(devices.contains { $0.uid == fallback.uid })
        #expect(AudioOutputDevice.find(uid: fallback.uid) == fallback)
        #expect(AudioOutputDevice.find(uid: "minimix-no-such-device") == nil)
    }

    @Test func unknownUIDThrows() throws {
        let engine = try makeOfflineEngine()
        #expect(throws: AudioEngineError.outputDeviceUnavailable("minimix-no-such-device")) {
            try engine.setOutputDevice(uid: "minimix-no-such-device")
        }
    }

    @Test func offlineEngineIgnoresDeviceChanges() throws {
        let engine = try makeOfflineEngine()
        // nil (predeterminada) y, si existe, un UID real: en offline no hay dispositivo que tocar.
        try engine.setOutputDevice(uid: nil)
        if let fallback = AudioOutputDevice.systemDefault() {
            try engine.setOutputDevice(uid: fallback.uid)
        }
        #expect(engine.outputDeviceID.load(ordering: .relaxed) == 0)
    }

    /// Tiempo real (si hay dispositivo): fijar la salida predeterminada explícitamente es un
    /// cambio válido (o un no-op si ya es la actual) y deja `outputDeviceID` apuntando a ella.
    @Test func realtimeEngineAdoptsExplicitDevice() throws {
        guard let fallback = AudioOutputDevice.systemDefault(),
              let engine = try? AudioEngine() else {
            print("[AV] sin motor en tiempo real (CI)")
            return
        }
        try engine.setOutputDevice(uid: fallback.uid)
        #expect(engine.outputDeviceID.load(ordering: .relaxed) == fallback.deviceID)
    }
}
