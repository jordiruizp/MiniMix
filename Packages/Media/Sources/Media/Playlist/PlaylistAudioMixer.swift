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
    /// Nodos de item conectados por este mezclador (para desconectarlos solo a ellos).
    private let connected = LockedState<[ObjectIdentifier: SendableAudioNode<AVAudioNode>]>([:])

    var node: AVAudioMixerNode { mixerRef.node }

    /// Conecta `itemNode` al mezclador si este ya está en un motor. Devuelve true si queda conectado.
    @discardableResult
    func connect(_ itemNode: AVAudioNode, gain: Float) -> Bool {
        let key = ObjectIdentifier(itemNode)
        if connected.withLock({ $0[key] != nil }) {
            setGain(gain, for: itemNode)
            return true
        }
        guard let engine = node.engine else { return false }
        if let owner = itemNode.engine, owner !== engine { return false }
        if itemNode.engine == nil { engine.attach(itemNode) }
        let mixerFormat = node.outputFormat(forBus: 0)
        let format: AVAudioFormat? = itemNode is AVAudioSourceNode
            ? itemNode.outputFormat(forBus: 0)
            : (mixerFormat.sampleRate > 0 ? mixerFormat : nil)
        setGain(gain, for: itemNode)
        engine.connect(itemNode, to: node, fromBus: 0, toBus: node.nextAvailableInputBus, format: format)
        connected.withLock { $0[key] = SendableAudioNode(node: itemNode) }
        return true
    }

    func setGain(_ gain: Float, for itemNode: AVAudioNode) {
        (itemNode as? AVAudioMixing)?.volume = gain
    }

    func isConnected(_ itemNode: AVAudioNode) -> Bool {
        connected.withLock { $0[ObjectIdentifier(itemNode)] != nil }
    }

    /// Desconecta y separa el nodo del item (lo adjuntó este mezclador o su fuente).
    func disconnect(_ itemNode: AVAudioNode) {
        guard connected.withLock({ $0.removeValue(forKey: ObjectIdentifier(itemNode)) }) != nil,
              let engine = itemNode.engine else { return }
        engine.disconnectNodeOutput(itemNode)
        engine.detach(itemNode)
    }
}
