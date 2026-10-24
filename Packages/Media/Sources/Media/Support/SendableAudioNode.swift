import AVFAudio

/// Referencia a un nodo de `AVAudioEngine` que puede cruzar hilos.
///
/// `@unchecked Sendable` justificado: la API de los nodos (`play`, `pause`,
/// `scheduleSegment`, `engine`…) se serializa internamente con el cerrojo del
/// motor (`AVAudioNodeImplBase::GetAttachAndEngineLock`) y el bloque de render
/// lo invoca el propio motor. El SDK de macOS 27 ya anota estos nodos como
/// `Sendable`; el de macOS 26 (CI, Swift 6.3) todavía no.
struct SendableAudioNode<Node: AVAudioNode>: @unchecked Sendable {
    let node: Node
}
