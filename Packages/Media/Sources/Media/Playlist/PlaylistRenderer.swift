import Core
import Metal
import Render
import Synchronization

/// GPU de una playlist (T71): fundido entre items, negro y copia de la última imagen.
///
/// - `composite` codifica la mezcla con el `Compositor` de Render en una textura del lienzo
///   sacada de un `TexturePool`, hace `commit` y devuelve la textura **sin esperar a la GPU**
///   (se puede llamar desde el hilo de render). Respeta el contrato de `VideoInput`: si ya
///   hay `maxInFlight` (3) command buffers de fundido sin completar, no codifica otro y
///   devuelve el último resultado.
/// - Las salidas sustituidas vuelven al pool cuando hay 3 más nuevas: el render que las leyó
///   (≤ 3 command buffers en vuelo) ya las codificó en la misma cola, y el seguimiento de
///   riesgos de Metal (texturas `.tracked` del pool) ordena la escritura del fundido que las
///   reutilice después de esa lectura. Así un fundido usa ~5 texturas del lienzo en total.
/// - Al terminar el fundido se vacía el pool (`purge`): no se retiene memoria entre fundidos.
/// - Los command buffers van a `context.commandQueue`: el render que lea la textura debe
///   usar la misma cola (orden garantizado) — es la de todo MiniMix.
final class PlaylistRenderer: Sendable {
    static let maxInFlight = 3

    private struct Output {
        var lastTime: HostTime?
        var last: MTLTexture?
        var retired: [MTLTexture] = []
        /// Texturas distintas usadas como salida desde el último `endComposite` (diagnóstico).
        var distinct: Set<ObjectIdentifier> = []
    }

    let context: MetalContext
    let canvasSize: PixelSize
    /// Inmutable tras `init`; en `LockedState` porque `MTLTexture` no es `Sendable`.
    private let black: LockedState<MTLTexture>
    var blackTexture: MTLTexture { black.current }
    private let compositor: Compositor
    private let pool: TexturePool
    private let inFlight = Atomic<Int>(0)
    private let output = LockedState(Output())
    private let composites = Atomic<Int>(0)

    init(context: MetalContext, canvasSize: PixelSize) throws {
        self.context = context
        self.canvasSize = canvasSize
        compositor = try Compositor(context: context, statsMode: .disabled)
        compositor.backgroundColor = .clear
        pool = TexturePool(device: context.device, memoryLimit: 64 << 20)
        guard let black = context.makeSolidColorTexture(.black, aspect: canvasSize) else {
            throw MediaError.metal("no se pudo crear la textura negra de la playlist")
        }
        self.black = LockedState(black)
    }

    /// Fundidos codificados (diagnóstico/tests).
    var compositeCount: Int { composites.load(ordering: .relaxed) }

    /// Texturas de salida distintas del fundido en curso (tests: el pool se reutiliza).
    var distinctOutputs: Int { output.withLock { $0.distinct.count } }

    /// Mezcla `from` → `to` con `mix` (ya curvado) en una textura del lienzo. No bloquea.
    func composite(from: MTLTexture?, to: MTLTexture?, mix: Float, fit: FitMode, time: HostTime) -> MTLTexture? {
        if let cached = output.withLock({ $0.lastTime == time ? $0.last : nil }) { return cached }
        let fallback = output.withLock { $0.last } ?? to ?? from
        guard reserveInFlight() else { return fallback }
        guard let target = pool.dequeue(width: canvasSize.width, height: canvasSize.height),
              let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            inFlight.subtract(1, ordering: .releasing)
            return fallback
        }
        commandBuffer.label = "MiniMix.PlaylistFade"
        compositor.encode(CompositorFrame(a: from, b: to, mix: mix, kind: .fade, fitA: fit, fitB: fit),
                          into: target, commandBuffer: commandBuffer)
        commandBuffer.addCompletedHandler { [weak self] _ in self?.inFlight.subtract(1, ordering: .releasing) }
        commandBuffer.commit()
        composites.add(1, ordering: .relaxed)
        let recyclable = output.withLock { o -> MTLTexture? in
            if let last = o.last { o.retired.append(last) }
            o.last = target
            o.lastTime = time
            o.distinct.insert(ObjectIdentifier(target))
            return o.retired.count > 3 ? o.retired.removeFirst() : nil
        }
        if let recyclable { pool.recycle(recyclable) }
        return target
    }

    /// Reserva un hueco de los `maxInFlight` (compare-exchange: sin carreras entre hilos).
    private func reserveInFlight() -> Bool {
        var current = inFlight.load(ordering: .relaxed)
        while current < Self.maxInFlight {
            let (exchanged, original) = inFlight.compareExchange(expected: current, desired: current + 1,
                                                                 ordering: .acquiringAndReleasing)
            if exchanged { return true }
            current = original
        }
        return false
    }

    /// Copia en GPU (blit, sin pasar por CPU) de `texture` a una textura propia: «última
    /// imagen visible» que sobrevive a la fuente que la produjo. No espera a la GPU; los
    /// command buffers posteriores de la misma cola ya ven la copia.
    func snapshot(_ texture: MTLTexture) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                            height: texture.height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        guard let copy = context.device.makeTexture(descriptor: desc),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        commandBuffer.label = "MiniMix.PlaylistSnapshot"
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        return copy
    }

    /// Fin de un fundido: suelta las salidas (el render puede tener la última en vuelo: su
    /// command buffer la retiene; no se recicla) y vacía el pool.
    func endComposite() {
        output.withLock { o in
            o.last = nil
            o.lastTime = nil
            o.retired.removeAll()
            o.distinct.removeAll()
        }
        pool.purge()
    }
}
