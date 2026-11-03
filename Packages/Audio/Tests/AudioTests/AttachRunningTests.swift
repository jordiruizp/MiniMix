import AVFAudio
import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// Attach con el motor en marcha de fuentes que no son generadores (p. ej. el `AVAudioMixerNode`
/// vacío de PlaylistInput o un efecto sin entrada). Antes del arreglo AVAudioEngine lanzaba
/// NSException («!srcNodeMixerConns.empty() && !isSrcNodeConnectedToIONode») y abortaba.
@Suite struct AttachRunningTests {
    @Test func emptyMixerSourceAttachesWhileOfflineEngineRuns() throws {
        let engine = try makeOfflineEngine()
        try engine.start()
        _ = try render(engine, frames: 1_024)

        let mixer = AVAudioMixerNode()
        let source = MockAudioSource(node: mixer)
        engine.setAudioFollowsProgram(false, for: source.id)
        try engine.attach(source)
        #expect(engine.attachedInputs == [source.id])
        #expect(peak(try render(engine, frames: 2_048), last: 480) == 0)

        // Como haría PlaylistInput: más tarde se le conecta un generador al mezclador vacío.
        let host = try #require(mixer.engine)
        let sine = try #require(makeSource(.sine(frequency: 1_000, amplitude: 0.5)).node)
        host.attach(sine)
        host.connect(sine, to: mixer, format: engine.format)
        #expect(abs(peak(try render(engine, frames: 2_048), last: 480) - 0.5) < 1e-3)

        engine.detach(source.id)
        _ = try render(engine, frames: 4_800)
        #expect(engine.retiringCount == 0)
        #expect(mixer.engine == nil)
    }

    @Test func effectWithoutInputAttachesWhileRunning() throws {
        let engine = try makeOfflineEngine()
        try engine.start()
        let source = MockAudioSource(node: AVAudioUnitEQ(numberOfBands: 1))
        try engine.attach(source)
        #expect(engine.attachedInputs == [source.id])
        _ = try render(engine, frames: 1_024)
    }

    /// Antes de arrancar seguía funcionando: el generador silencioso no cambia nada ahí.
    @Test func emptyMixerSourceAttachesBeforeStart() throws {
        let engine = try makeOfflineEngine()
        let source = MockAudioSource(node: AVAudioMixerNode())
        try engine.attach(source)
        try engine.start()
        #expect(peak(try render(engine, frames: 1_024), last: 480) == 0)
    }

    /// Tiempo real (si hay dispositivo; en CI puede no haberlo y se omite).
    @Test func emptyMixerSourceAttachesWhileRealtimeEngineRuns() throws {
        guard let engine = try? AudioEngine() else { return }
        engine.setMasterVolume(0)
        do { try engine.start() } catch {
            print("[attach] motor en tiempo real no arrancó (sin dispositivo): \(error)")
            return
        }
        defer { engine.stop() }
        let source = MockAudioSource(node: AVAudioMixerNode())
        try engine.attach(source)
        #expect(engine.attachedInputs == [source.id])
        engine.detach(source.id)
        #expect(engine.attachedInputs.isEmpty)
    }
}
