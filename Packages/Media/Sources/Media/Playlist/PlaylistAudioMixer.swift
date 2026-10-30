import AVFAudio
import Foundation

/// Audio de una playlist: **un solo nodo** (`AVAudioMixerNode`) hacia el canal de Audio (E).
///
/// Por qué un mezclador propio: los nodos de los items (el `AVAudioSourceNode` del tap de
/// `VideoInput`, el `AVAudioPlayerNode` de `AudioInput`) son nodos del motor; la única forma
/// de sumarlos dentro del grafo es conectarlos a un mezclador, y `AVAudioMixing.volume`
/// (por entrada del mezclador) aplica las ganancias del fundido sin DSP propio. Un
/// `AVAudioSourceNode` que mezclara a mano no puede «tirar» de un `AVAudioPlayerNode`.
///
/// E adjunta `node` a su motor (`AudioEngine.attach`); desde ese momento (`node.engine`)
/// este mezclador adjunta y conecta los nodos de los items cargados (como mucho 2) y los
/// separa al liberarlos. Todo se llama desde la cola de control de la playlist, nunca desde
/// un callback de audio.
final class PlaylistAudioMixer: Sendable {
    private let mixerRef = SendableAudioNode(node: AVAudioMixerNode())
    /// Nodos de item que adjuntó este mezclador (los separa él: al liberar el item, al
    /// moverse el mezclador a otro motor y en `teardown`).
    private let owned = LockedState<[ObjectIdentifier: SendableAudioNode<AVAudioNode>]>([:])

    var node: AVAudioMixerNode { mixerRef.node }

    /// Conecta `itemNode` al mezclador si este ya está en un motor. Devuelve true si queda conectado.
    ///
    /// Si E volvió a adjuntar el mezclador a otro motor, el nodo del item se separa del motor
    /// antiguo y se conecta al nuevo. Nunca se conecta un nodo que esté en otro motor ajeno.
    /// (E no debe separar `node` mientras se llama: si lo hace entre la comprobación y
    /// `connect`, AVAudioEngine lanzaría una excepción; se reduce la ventana comprobando
    /// justo antes.)
    @discardableResult
    func connect(_ itemNode: AVAudioNode, gain: Float) -> Bool {
        guard let engine = node.engine else { return false }
        if isConnected(itemNode) {
            setGain(gain, for: itemNode)
            return true
        }
        let key = ObjectIdentifier(itemNode)
        if let other = itemNode.engine, other !== engine {
            guard owned.withLock({ $0[key] != nil }) else { return false }
            other.disconnectNodeOutput(itemNode)
            other.detach(itemNode)
        }
        if itemNode.engine == nil {
            engine.attach(itemNode)
            owned.withLock { $0[key] = SendableAudioNode(node: itemNode) }
        }
        let mixerFormat = node.outputFormat(forBus: 0)
        let format: AVAudioFormat? = itemNode is AVAudioSourceNode
            ? itemNode.outputFormat(forBus: 0)
            : (mixerFormat.sampleRate > 0 ? mixerFormat : nil)
        setGain(gain, for: itemNode)
        guard node.engine === engine, itemNode.engine === engine else { return false }
        engine.connect(itemNode, to: node, fromBus: 0, toBus: node.nextAvailableInputBus, format: format)
        return true
    }

    func setGain(_ gain: Float, for itemNode: AVAudioNode) {
        (itemNode as? AVAudioMixing)?.volume = gain
    }

    /// Conectado de verdad a este mezclador en su motor actual (no un mapa local).
    func isConnected(_ itemNode: AVAudioNode) -> Bool {
        guard let engine = node.engine, itemNode.engine === engine else { return false }
        return engine.outputConnectionPoints(for: itemNode, outputBus: 0).contains { $0.node === node }
    }

    /// Desconecta el nodo del item; si lo adjuntó este mezclador, también lo separa del motor.
    func disconnect(_ itemNode: AVAudioNode) {
        let wasOwned = owned.withLock { $0.removeValue(forKey: ObjectIdentifier(itemNode)) } != nil
        guard let engine = itemNode.engine else { return }
        engine.disconnectNodeOutput(itemNode)
        if wasOwned { engine.detach(itemNode) }
    }

    /// Separa todos los nodos de item que adjuntó (al destruir la playlist).
    func teardown() {
        let nodes = owned.withLock { o -> [AVAudioNode] in
            defer { o.removeAll() }
            return o.values.map(\.node)
        }
        for itemNode in nodes {
            guard let engine = itemNode.engine else { continue }
            engine.disconnectNodeOutput(itemNode)
            engine.detach(itemNode)
        }
    }

    /// Igual que `teardown`, pero fuera del hilo que llama (p. ej. el `deinit` de la playlist
    /// en el hilo de render, que no debe tomar el cerrojo del motor): rampa de 20 ms a 0 y
    /// después desconexión, en una cola de utilidad. Solo captura los nodos (envueltos).
    func teardownLater() {
        let nodes = owned.withLock { o -> [SendableAudioNode<AVAudioNode>] in
            defer { o.removeAll() }
            return Array(o.values)
        }
        guard !nodes.isEmpty else { return }
        let queue = DispatchQueue.global(qos: .utility)
        let ramp = 0.02
        queue.async {
            let starts = nodes.map { ($0.node as? AVAudioMixing)?.volume ?? 1 }
            for step in 1...4 {
                queue.asyncAfter(deadline: .now() + ramp * Double(step) / 4) {
                    for (ref, start) in zip(nodes, starts) {
                        (ref.node as? AVAudioMixing)?.volume = start * Float(1 - Double(step) / 4)
                    }
                }
            }
            queue.asyncAfter(deadline: .now() + ramp + 0.005) {
                for ref in nodes {
                    guard let engine = ref.node.engine else { continue }
                    engine.disconnectNodeOutput(ref.node)
                    engine.detach(ref.node)
                }
            }
        }
    }

    var ownedCount: Int { owned.withLock { $0.count } }
}
