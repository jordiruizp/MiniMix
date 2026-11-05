import AVFAudio

extension AudioEngine {
    /// Ejecuta un cambio de grafo ajeno al `AudioEngine` (p. ej. el mezclador de una playlist que
    /// conecta y desconecta los nodos de sus items) **bajo el mismo cerrojo** que `attach`,
    /// `detach`, `start`, `stop` y el rearranque tras un cambio de configuración, para que no
    /// coincida con ellos: `AVAudioEngine` no garantiza seguridad entre hilos en sus mutaciones.
    ///
    /// Reglas para `body`:
    /// - **No reentrar en `AudioEngine`** (ni en ningún método suyo): el cerrojo no es recursivo y
    ///   se bloquearía.
    /// - Solo cambios de grafo (`attach`, `connect`, `disconnectNodeInput/Output`, `detach`) de
    ///   nodos propios del llamante; no tocar los nodos del `AudioEngine` ni parar/arrancar el
    ///   motor, ni guardar la referencia a `engine` fuera del cierre.
    /// - Corto y sin esperas (E/S, `await`, semáforos): mientras dura, las demás llamadas al
    ///   `AudioEngine` esperan. El hilo de audio nunca toma este cerrojo, así que no se bloquea.
    /// - No llamarlo desde el hilo de audio.
    public func performGraphChange<R>(_ body: (AVAudioEngine) throws -> R) rethrows -> R {
        // Excepción documentada de `LockedState`: el resultado no tiene por qué ser `Sendable`
        // (lo decide el llamante); el motor no escapa del cierre.
        try state.withLockUnchecked { state in try body(state.engine) }
    }
}
