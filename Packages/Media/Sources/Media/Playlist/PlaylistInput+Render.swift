import Core
import Metal

extension PlaylistInput {
    /// Hilo de render: solo el cerrojo corto del estado y, durante un fundido, un command
    /// buffer que se envía sin esperar (`PlaylistRenderer.composite`).
    ///
    /// Orden: fundido programado/en curso → corte programado (desde su tick, con medio
    /// fotograma de tolerancia) → visual actual. Si el entrante aún no tiene textura se
    /// sigue mostrando el saliente (nunca negro por un cambio).
    public func texture(for time: HostTime) -> MTLTexture? {
        let (fade, armed, shown, frame, fit, fallback) = state.withLock { s in
            (s.fade, s.armed, s.shown, s.frameDuration, s.fit, s.fallback)
        }
        if let fade, time.seconds >= fade.start.seconds - frame / 2 {
            let progress = fade.duration > 0 ? (time - fade.start) / fade.duration : 1
            let incoming = resolve(fade.to, at: time)
            if progress >= 1 { return incoming ?? resolve(fade.from, at: time) }
            let outgoing = resolve(fade.from, at: time)
            guard let incoming else { return outgoing }
            let mix = Float(TransitionCurve.videoMix(max(0, progress)))
            return renderer.composite(from: outgoing, to: incoming, mix: mix, fit: fit, time: time)
        }
        if let armed, time.seconds >= armed.at.seconds - frame / 2, let texture = resolve(armed.visual, at: time) {
            return texture
        }
        if let texture = shown.flatMap({ resolve($0, at: time) }) {
            if fallback != nil { state.withLock { $0.fallback = nil } }
            return texture
        }
        return fallback.flatMap { resolve($0, at: time) }
    }

    private func resolve(_ visual: Visual, at time: HostTime) -> MTLTexture? {
        switch visual {
        case .source(let source): source.texture(for: time)
        case .texture(let texture): texture
        case .black: renderer.blackTexture
        }
    }
}
