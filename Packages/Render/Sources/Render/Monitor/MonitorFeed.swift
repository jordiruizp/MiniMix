import Metal

/// Canal entre quien renderiza (cualquier hilo) y uno o varios monitores.
///
/// El render llama a `display(_:)` con la textura del lienzo de cada fotograma;
/// cada observador (p. ej. un `MonitorView`) recibe una petición de redibujado,
/// agrupadas: como máximo una pendiente por observador hasta que dibuja. Un mismo
/// feed puede alimentar varias vistas, y una vista recreada con el mismo feed no
/// interfiere con la anterior: cada una se da de baja solo con su propio token.
/// La textura no debe reescribirse mientras se muestra: el productor debe rotar
/// texturas (p. ej. con `TexturePool`) en lugar de reutilizar siempre la misma.
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
        var texture: MTLTexture?
        var observers: [UInt64: Observer] = [:]
        var nextID: UInt64 = 0
    }

    private let state = UnfairLocked(State())

    public init() {}

    /// Publica la textura a mostrar y pide un redibujado a cada observador que no
    /// tenga ya uno pendiente. Seguro desde cualquier hilo; los avisos se llaman
    /// fuera del cerrojo.
    public func display(_ texture: MTLTexture?) {
        let handlers: [@Sendable () -> Void] = state.withLock { st in
            st.texture = texture
            var due: [@Sendable () -> Void] = []
            for (id, observer) in st.observers where !observer.pending {
                st.observers[id]?.pending = true
                due.append(observer.handler)
            }
            return due
        }
        for handler in handlers { handler() }
    }

    /// Última textura publicada.
    public var currentTexture: MTLTexture? { state.withLock { $0.texture } }

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

    /// El observador toma la textura actual y libera su petición pendiente.
    public func takeForDrawing(_ token: ObserverToken) -> MTLTexture? {
        state.withLock { st in
            st.observers[token.id]?.pending = false
            return st.texture
        }
    }
}
