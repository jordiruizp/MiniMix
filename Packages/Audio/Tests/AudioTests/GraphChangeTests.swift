import AVFAudio
import Core
import CoreMocks
import Foundation
import Testing
@testable import Audio

/// Lleva el mezclador y el formato a la tarea concurrente del test. `@unchecked Sendable`: el SDK
/// del CI (macOS 26) no anota los nodos/formatos de AVFAudio como `Sendable`; aquí solo se usan
/// dentro de `performGraphChange` (bajo el cerrojo del motor) o son inmutables (formato).
private struct GraphHandles: @unchecked Sendable {
    let mixer: AVAudioMixerNode
    let format: AVAudioFormat
}

/// `performGraphChange`: cambios de grafo externos (mezclador de playlist) serializados con
/// attach/detach/render del `AudioEngine`.
@Suite struct GraphChangeTests {
    /// Conecta/desconecta nodos de items en un mezclador (como `PlaylistAudioMixer`) desde otra
    /// cola mientras el hilo del test da de alta/baja otros canales y renderiza. Sin el cerrojo
    /// compartido esto produce NSException o corrupción del grafo de AVAudioEngine.
    @Test func concurrentExternalChangesWithAttachDetachAndRender() async throws {
        let engine = try makeOfflineEngine()
        let mixer = AVAudioMixerNode()
        let playlist = MockAudioSource(node: mixer)
        engine.setAudioFollowsProgram(false, for: playlist.id)
        try engine.attach(playlist)
        try engine.start()
        let handles = GraphHandles(mixer: mixer, format: engine.format)

        let iterations = 200
        let external = Task.detached {
            let mixer = handles.mixer
            let format = handles.format
            for index in 0..<iterations {
                let item = makeSource(.sine(frequency: 1_000, amplitude: 0.1)).node!
                engine.performGraphChange { avEngine in
                    avEngine.attach(item)
                    avEngine.connect(item, to: mixer, fromBus: 0, toBus: mixer.nextAvailableInputBus, format: format)
                }
                if index % 3 == 0 { await Task.yield() }
                engine.performGraphChange { avEngine in
                    avEngine.disconnectNodeOutput(item)
                    avEngine.detach(item)
                }
            }
            return iterations
        }

        var rendered = 0
        for index in 0..<iterations {
            let other = makeSource(.sine(frequency: 500, amplitude: 0.1))
            engine.setAudioFollowsProgram(false, for: other.id)
            try engine.attach(other)
            _ = try render(engine, frames: 512)
            rendered += 512
            engine.detach(other.id)
            if index % 4 == 0 { _ = try render(engine, frames: 512) }
        }
        let done = await external.value
        #expect(done == iterations)
        _ = try render(engine, frames: 4_800) // termina las bajas diferidas
        #expect(engine.attachedInputs == [playlist.id])
        #expect(engine.retiringCount == 0)
        // El mezclador de la playlist queda solo con su conexión de salida.
        let leftovers = engine.performGraphChange { avEngine in
            (0..<mixer.numberOfInputs).compactMap { avEngine.inputConnectionPoint(for: mixer, inputBus: $0) }.count
        }
        #expect(leftovers == 0)
        print("[graph] \(iterations) cambios externos concurrentes con \(iterations) attach/detach y \(rendered) muestras")
    }

    @Test func returnsValueAndRethrows() throws {
        let engine = try makeOfflineEngine()
        let running = engine.performGraphChange { $0.isRunning }
        #expect(running == false)
        struct Failure: Error {}
        #expect(throws: Failure.self) { try engine.performGraphChange { _ in throw Failure() } }
        // El cerrojo se libera tras lanzar: el motor sigue usable.
        try engine.attach(makeSource(.silence))
        #expect(engine.attachedInputs.count == 1)
    }
}
