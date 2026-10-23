import Metal

/// Canal entre quien renderiza (cualquier hilo) y uno o varios monitores.
///
/// El render llama a `display(_:)` con la textura del lienzo de cada fotograma;
/// cada observador (p. ej. un `MonitorView`) recibe una petición de redibujado,
/// agrupadas: como máximo una pendiente por observador hasta que dibuja. Un mismo
/// feed puede alimentar varias vistas, y una vista recreada con el mismo feed no
/// interfiere con la anterior: cada una se da de baja solo con su propio token.
///
/// **Regla de propiedad de la textura publicada:**
/// - Con `display(_:returningTo: pool)` la textura pasa a ser del feed: el
///   productor no debe volver a escribirla ni reciclarla. El feed la devuelve a
///   `pool` cuando (1) otra textura la sustituye y (2) han terminado todos los
///   command buffers de monitor que la leían (`TextureLease`).
/// - Con `display(_:)` sin pool, el productor conserva la propiedad y debe
///   garantizar que no la reescribe ni la recicla mientras sea la actual o haya
///   monitores dibujándola; lo normal es usar la variante con pool.
public final class MonitorFeed: @unchecked Sendable {
    /// Identifica a un observador registrado con `addObserver(_:)`.
    public struct ObserverToken: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private struct Observer {
        var handler: @Sendable () -> Void
        var pending = false
    }

    private struct State {
        var published: PublishedTexture?
        var observers: [UInt64: Observer] = [:]
        var nextID: UInt64 = 0
    }

    private let state = UnfairLocked(State())

    public init() {}

    deinit {
        state.withLock { $0.published }?.release()
    }

    /// Publica la textura a mostrar y pide un redibujado a cada observador que no
    /// tenga ya uno pendiente. Seguro desde cualquier hilo; los avisos se llaman
    /// fuera del cerrojo. Con `pool`, la textura anterior vuelve al pool cuando ya
    /// nadie la usa (ver la regla de propiedad arriba).
    public func display(_ texture: MTLTexture?, returningTo pool: TexturePool? = nil) {
        let (previous, handlers): (PublishedTexture?, [@Sendable () -> Void]) = state.withLock { st in
            // La misma textura otra vez: se conserva su recuento (y su pool) y solo se notifica.
            let previous: PublishedTexture?
            if let current = st.published, current.texture === texture {
                previous = nil
            } else {
                previous = st.published
                st.published = texture.map { PublishedTexture(texture: $0, pool: pool) }
            }
            var due: [@Sendable () -> Void] = []
            for (id, observer) in st.observers where !observer.pending {
                st.observers[id]?.pending = true
                due.append(observer.handler)
            }
            return (previous, due)
        }
        previous?.release()
        for handler in handlers { handler() }
    }

    /// Última textura publicada. Solo informativa: **no** pasa por el lease, así
    /// que no debe usarse para dibujar (puede volver al pool en cualquier momento);
    /// para dibujar, `acquireForDrawing(_:)`.
    public var currentTexture: MTLTexture? { state.withLock { $0.published?.texture } }

    /// Registra un observador; `handler` se llama (en cualquier hilo) cuando hay
    /// una textura nueva y el observador no tenía ya un redibujado pendiente.
    public func addObserver(_ handler: @escaping @Sendable () -> Void) -> ObserverToken {
        state.withLock { st in
            st.nextID &+= 1
            st.observers[st.nextID] = Observer(handler: handler)
            return ObserverToken(id: st.nextID)
        }
    }

    /// Da de baja solo al observador de `token` (no afecta a los demás).
    public func removeObserver(_ token: ObserverToken) {
        state.withLock { _ = $0.observers.removeValue(forKey: token.id) }
    }

    public var observerCount: Int { state.withLock { $0.observers.count } }

    /// El observador toma la textura actual (prestada) y libera su petición pendiente.
    /// Cada llamada devuelve un `TextureLease` propio, que su dueño debe soltar con
    /// `release(after:)` (command buffer que la lee) o `release()` si no codifica nada.
    public func acquireForDrawing(_ token: ObserverToken) -> TextureLease? {
        let published: PublishedTexture? = state.withLock { st in
            st.observers[token.id]?.pending = false
            st.published?.retain()
            return st.published
        }
        return published.map(TextureLease.init)
    }
}

/// Textura publicada en un feed, con recuento de referencias: una mientras es la
/// actual y una por cada `TextureLease` vivo. Al llegar a cero vuelve a su pool.
final class PublishedTexture: @unchecked Sendable {
    let texture: MTLTexture
    private let pool: TexturePool?
    private let refs = UnfairLocked(1)

    init(texture: MTLTexture, pool: TexturePool?) {
        self.texture = texture
        self.pool = pool
    }

    func retain() {
        refs.withLock { $0 += 1 }
    }

    func release() {
        let remaining = refs.withLock { count -> Int in
            count -= 1
            return count
        }
        assert(remaining >= 0, "PublishedTexture over-released")
        if remaining == 0 { pool?.recycle(texture) }
    }

    var referenceCount: Int { refs.withLock { $0 } }
}

/// Préstamo de **una** adquisición (`MonitorFeed.acquireForDrawing`) de la textura
/// publicada. Soltarlo es idempotente: un consumidor solo puede soltar su propia
/// referencia, nunca la de otro monitor.
public final class TextureLease: @unchecked Sendable {
    private let published: PublishedTexture
    private let released = UnfairLocked(false)

    init(_ published: PublishedTexture) {
        self.published = published
    }

    public var texture: MTLTexture { published.texture }

    /// Suelta este préstamo ya. Las llamadas siguientes no hacen nada.
    public func release() {
        let first = released.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { published.release() }
    }

    /// Suelta este préstamo cuando `commandBuffer` termine (llamar antes de `commit`).
    public func release(after commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [self] _ in release() }
    }

    public var isReleased: Bool { released.withLock { $0 } }
}
