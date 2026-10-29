import Foundation
import Testing
@testable import Audio

/// Consulta de latencia del dispositivo de salida (HAL). En CI puede no haber dispositivo:
/// entonces solo se comprueba que no falla. Se imprime siempre lo medido.
@Suite struct OutputLatencyTests {
    @Test func presentationLatencyFormula() {
        let latency = OutputLatency(deviceID: 1, deviceName: "x", sampleRate: 48_000, deviceFrames: 480,
                                    streamFrames: 96, safetyOffsetFrames: 144, bufferFrames: 512)
        #expect(abs(latency.presentationSeconds - 0.015) < 1e-9)
        #expect(abs(latency.bufferSeconds - 512.0 / 48_000) < 1e-12)
        #expect(OutputLatency(deviceID: 1, deviceName: "x", sampleRate: 0, deviceFrames: 1, streamFrames: 1,
                              safetyOffsetFrames: 1, bufferFrames: 1).presentationSeconds == 0)
    }

    @Test func defaultOutputDeviceIsReadable() throws {
        guard let latency = OutputLatency.defaultOutputDevice() else {
            print("[AV] sin dispositivo de salida por defecto (CI)")
            return
        }
        print("[AV] salida \(latency.deviceName): \(latency.sampleRate) Hz, device \(latency.deviceFrames) + "
              + "stream \(latency.streamFrames) + safety \(latency.safetyOffsetFrames) muestras = "
              + "\(latency.presentationSeconds * 1_000) ms; búfer \(latency.bufferFrames) (\(latency.bufferSeconds * 1_000) ms)")
        #expect(latency.sampleRate > 0)
        #expect(latency.presentationSeconds >= 0 && latency.presentationSeconds < 1)
    }

    @Test func engineReportsItsOutputDevice() throws {
        let offline = try makeOfflineEngine()
        #expect(offline.outputLatency == nil)
        #expect(offline.outputPresentationLatency == 0)
        let realtime = try AudioEngine()
        if let latency = realtime.outputLatency {
            print("[AV] motor: \(latency.deviceName) \(latency.presentationSeconds * 1_000) ms; "
                  + "presentationLatency \(realtime.outputPresentationLatency * 1_000) ms")
            #expect(latency.presentationSeconds >= 0)
        }
    }
}
