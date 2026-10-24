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
/// - Las salidas sustituidas vuelven al pool solo cuando hay 3 más nuevas y tienen
///   ≥ 200 ms (las puede estar leyendo el render de Programa); por encima de 6 se sueltan
///   sin reciclar (el command buffer que las lea las retiene).
/// - Los command buffers van a `context.commandQueue`: el render que lea la textura debe
///   usar la misma cola (orden garantizado) — es la de todo MiniMix.
final class PlaylistRenderer: Sendable {
    static let maxInFlight = 3

    private struct Output {
        var lastTime: HostTime?
        var last: MTLTexture?
        var retired: [(texture: MTLTexture, at: Int64)] = []
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

    /// Mezcla `from` → `to` con `mix` (ya curvado) en una textura del lienzo. No bloquea.
    func composite(from: MTLTexture?, to: MTLTexture?, mix: Float, fit: FitMode, time: HostTime) -> MTLTexture? {
        if let cached = output.withLock({ $0.lastTime == time ? $0.last : nil }) { return cached }
        let previous = output.withLock { $0.last }
        guard inFlight.load(ordering: .acquiring) < Self.maxInFlight,
              let target = pool.dequeue(width: canvasSize.width, height: canvasSize.height),
              let commandBuffer = context.commandQueue.makeCommandBuffer() else { return previous ?? to ?? from }
        commandBuffer.label = "MiniMix.PlaylistFade"
        compositor.encode(CompositorFrame(a: from, b: to, mix: mix, kind: .fade, fitA: fit, fitB: fit),
                          into: target, commandBuffer: commandBuffer)
        inFlight.add(1, ordering: .releasing)
        commandBuffer.addCompletedHandler { [weak self] _ in self?.inFlight.subtract(1, ordering: .releasing) }
        commandBuffer.commit()
        composites.add(1, ordering: .relaxed)
        let now = HostClock.nowNanos()
        let recyclable = output.withLock { o -> [MTLTexture] in
            if let last = o.last { o.retired.append((last, now)) }
            o.last = target
            o.lastTime = time
            var out: [MTLTexture] = []
            while o.retired.count > 6 { o.retired.removeFirst() }
            while o.retired.count > 3, let first = o.retired.first, now - first.at >= 200_000_000 {
                out.append(o.retired.removeFirst().texture)
            }
            return out
        }
        recyclable.forEach { pool.recycle($0) }
        return target
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

    /// Fin de un fundido: suelta la salida actual (el render puede tenerla en vuelo; el
    /// command buffer la retiene, pero no se recicla).
    func endComposite() {
        output.withLock { o in
            o.last = nil
            o.lastTime = nil
            o.retired.removeAll()
        }
    }
}
