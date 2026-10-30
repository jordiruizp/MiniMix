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
        // Sin dispositivo (CI) crear el motor en tiempo real puede fallar: se tolera como el nil.
        guard let realtime = try? AudioEngine() else {
            print("[AV] AudioEngine() en tiempo real no disponible (sin dispositivo)")
            return
        }
        if let latency = realtime.outputLatency {
            print("[AV] motor: \(latency.deviceName) \(latency.presentationSeconds * 1_000) ms; "
                  + "presentationLatency \(realtime.outputPresentationLatency * 1_000) ms")
            #expect(latency.presentationSeconds >= 0)
        }
    }

    /// Tiempo real (si hay dispositivo): la sonda consulta la latencia desde el hilo del tap
    /// mientras se quita bajo el cerrojo; arrancar, medir y parar no debe bloquearse.
    @Test func realtimeOnsetProbeStartsAndStops() async throws {
        guard let engine = try? AudioEngine() else { return }
        let source = makeSource(.sine(frequency: 1_000, amplitude: 0.5))
        engine.setAudioFollowsProgram(false, for: source.id)
        engine.setMasterVolume(0) // no sonar
        try engine.attach(source)
        let onsets = engine.startOnsetDetection(threshold: 0, holdOff: 0.01)
        do { try engine.start() } catch {
            print("[AV] el motor en tiempo real no arrancó (sin dispositivo): \(error)")
            engine.stopOnsetDetection()
            return
        }
        try await Task.sleep(for: .milliseconds(150))
        engine.stopOnsetDetection()
        engine.stop()
        var count = 0
        for await onset in onsets {
            count += 1
            #expect(onset.presentationHostTime != nil)
        }
        print("[AV] sonda en tiempo real: \(count) inicios en 150 ms")
    }
}
