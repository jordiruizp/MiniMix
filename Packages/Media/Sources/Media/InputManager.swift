import Core
import Foundation
import Render

/// Alta/baja/edición de entradas y control de decodificación (T32, contracts-v2).
///
/// - Crea la fuente adecuada para cada `InputDescriptor` y la prepara.
/// - `.playlist` se delega en `playlistFactory` (PlaylistInput, agente D); sin
///   fábrica, `add` lanza `MediaError.unsupported`.
/// - `setVisible`: las entradas no visibles se pausan (rate 0, sin decodificar)
///   sin perder su estado lógico; de las visibles, como mucho
///   `maxActiveVideoDecoders` (4) decodifican vídeo, **por orden de alta**.
///   Hasta la primera llamada a `setVisible` todas cuentan como visibles.
/// - Las entradas de solo audio no se pausan al ocultarlas (su audio no depende
///   de que se vean).
/// - Concurrencia: las decisiones de decodificación se aplican dentro del cerrojo,
///   en orden (primero se deshabilita y luego se habilita), así que nunca hay más de
///   4 decodificadores habilitados ni un `setVisible` antiguo pisa a uno nuevo. Por
///   eso `DecodingControllable.setDecodingEnabled` no debe llamar al `InputManager`.
/// - `remove` durante un `add` en curso lo cancela (no «resucita»); dos `add` del
///   mismo id no preparan dos fuentes (el segundo lanza `duplicate`).
/// - `remove` no desconecta el nodo de audio: eso es de `AudioEngine.detach` (T80).
public final class InputManager: InputManaging {
    public typealias PlaylistFactory = @Sendable (InputDescriptor) async throws -> FrameSource
    public typealias URLResolver = @Sendable (MediaReference) throws -> URL

    struct Entry {
        let id: InputID
        var source: FrameSource
        var descriptor: InputDescriptor
    }

    struct Pending {
        let token: UUID
        let task: Task<FrameSource, Error>
    }

    struct State {
        /// En orden de alta (decide qué decodificadores ganan si hay más de 4 visibles).
        var entries: [Entry] = []
        /// Altas en curso (aún preparando).
        var pending: [InputID: Pending] = [:]
        var visible: Set<InputID>?
        var activeDecoders: Set<InputID> = []
    }

    public let context: MetalContext
    public let canvasSize: PixelSize
    public let maxActiveVideoDecoders: Int
    public let textureCache: VideoTextureCache
    let imageLoader: ImageInput.Loader
    let urlResolver: URLResolver
    let playlistFactory: PlaylistFactory?
    let state = LockedState(State())

    /// - Parameters:
    ///   - imageLoader: cargador de imágenes (por defecto `ImageTextureLoader` de Render).
    ///   - urlResolver: resuelve `MediaReference` → URL (Persistence resuelve los
    ///     bookmarks; por defecto se usa `path`).
    ///   - playlistFactory: crea la fuente de una entrada `.playlist`.
    public init(context: MetalContext, canvasSize: PixelSize = .hd1080, maxActiveVideoDecoders: Int = 4,
                imageLoader: ImageInput.Loader? = nil,
                urlResolver: @escaping URLResolver = { URL(fileURLWithPath: $0.path) },
                playlistFactory: PlaylistFactory? = nil) {
        self.context = context
        self.canvasSize = canvasSize
        self.maxActiveVideoDecoders = maxActiveVideoDecoders
        textureCache = VideoTextureCache(context: context)
        let loader = ImageTextureLoader(context: context)
        self.imageLoader = imageLoader ?? { url, size in try await loader.loadTexture(from: url, maxSize: size) }
        self.urlResolver = urlResolver
        self.playlistFactory = playlistFactory
    }

    // MARK: InputManaging

    public func add(_ descriptor: InputDescriptor) async throws {
        let id = descriptor.id
        let token = UUID()
        let task = try state.withLock { s -> Task<FrameSource, Error> in
            guard s.pending[id] == nil, !s.entries.contains(where: { $0.id == id }) else {
                throw MediaError.duplicate(id.description)
            }
            let task = Task { try await self.makePreparedSource(for: descriptor) }
            s.pending[id] = Pending(token: token, task: task)
            return task
        }
        let source: FrameSource
        do {
            source = try await task.value
        } catch {
            state.withLock { s in if s.pending[id]?.token == token { s.pending[id] = nil } }
            throw error
        }
        let inserted = state.withLock { s -> Bool in
            guard s.pending[id]?.token == token else { return false }
            s.pending[id] = nil
            s.entries.append(Entry(id: id, source: source, descriptor: descriptor))
            applyVisibilityLocked(&s)
            return true
        }
        guard inserted else {
            Self.discard(source)
            throw MediaError.cancelled(id.description)
        }
    }

    public func remove(_ id: InputID) async {
        let (pending, removed) = state.withLock { s -> (Pending?, FrameSource?) in
            let pending = s.pending.removeValue(forKey: id)
            var removed: FrameSource?
            if let index = s.entries.firstIndex(where: { $0.id == id }) {
                removed = s.entries.remove(at: index).source
                applyVisibilityLocked(&s)
            }
            return (pending, removed)
        }
        pending?.task.cancel()
        if let removed { Self.discard(removed) }
    }

    /// Aplica en directo un descriptor editado (contracts-v2):
    /// - loop e In/Out: en la fuente existente (vídeo y audio).
    /// - color: `ColorInput.setColor`.
    /// - fit: solo se guarda (lo aplica el compositor; ver `descriptor(for:)`).
    /// - contenido nuevo (otra ruta, otro tipo, otra cartela, otra playlist): se crea y
    ///   prepara una fuente nueva y se sustituye en el mismo puesto (conserva la
    ///   prioridad de decodificador y la visibilidad); si la anterior estaba en play,
    ///   la nueva arranca.
    public func update(_ descriptor: InputDescriptor) async throws {
        let id = descriptor.id
        await waitForPendingAdd(id)
        guard let entry = state.withLock({ s in s.entries.first { $0.id == id } }) else {
            throw MediaError.notFound(id.description)
        }
        if Self.needsReplacement(entry.descriptor.content, descriptor.content) {
            try await replace(entry, with: descriptor)
        } else {
            try Self.applyInPlace(descriptor, to: entry.source)
            state.withLock { s in
                if let index = s.entries.firstIndex(where: { $0.id == id && $0.source === entry.source }) {
                    s.entries[index].descriptor = descriptor
                }
            }
        }
    }

    public func frameSource(for id: InputID) -> FrameSource? {
        state.withLock { s in s.entries.first { $0.id == id }?.source }
    }

    public func audioSource(for id: InputID) -> AudioSource? {
        guard let audio = frameSource(for: id) as? AudioSource, audio.node != nil else { return nil }
        return audio
    }

    public func setVisible(_ ids: Set<InputID>) {
        state.withLock { s in
            s.visible = ids
            applyVisibilityLocked(&s)
        }
    }

    // MARK: Consulta

    public var inputIDs: [InputID] { state.withLock { $0.entries.map(\.id) } }

    /// Último descriptor aplicado (incluye `fit`, que Media no usa).
    public func descriptor(for id: InputID) -> InputDescriptor? {
        state.withLock { s in s.entries.first { $0.id == id }?.descriptor }
    }

    /// Entradas cuyo decodificador de vídeo está habilitado ahora mismo.
    public var activeDecoderIDs: Set<InputID> { state.withLock { $0.activeDecoders } }
}

// MARK: - Internos

extension InputManager {
    private func makePreparedSource(for descriptor: InputDescriptor) async throws -> FrameSource {
        let source = try await makeSource(for: descriptor)
        try await source.prepare()
        try Task.checkCancellation()
        return source
    }

    private func makeSource(for descriptor: InputDescriptor) async throws -> FrameSource {
        let id = descriptor.id
        switch descriptor.content {
        case .video(let ref):
            return VideoInput(id: id, url: try urlResolver(ref), textureCache: textureCache,
                              loop: descriptor.loop, inPoint: descriptor.inPoint, outPoint: descriptor.outPoint)
        case let .audio(ref, visual):
            let visualSource: FrameSource = switch visual {
            case .black, .lastImage: ColorInput(color: .black, context: context, canvasSize: canvasSize)
            case .card(let card): ImageInput(url: try urlResolver(card), canvasSize: canvasSize, loader: imageLoader)
            }
            return AudioInput(id: id, url: try urlResolver(ref), visual: visualSource,
                              loop: descriptor.loop, inPoint: descriptor.inPoint, outPoint: descriptor.outPoint)
        case .image(let ref):
            return ImageInput(id: id, url: try urlResolver(ref), canvasSize: canvasSize, loader: imageLoader)
        case .color(let color):
            return ColorInput(id: id, color: color, context: context, canvasSize: canvasSize)
        case .playlist:
            guard let playlistFactory else { throw MediaError.unsupported("playlist sin fábrica (PlaylistInput)") }
            return try await playlistFactory(descriptor)
        }
    }

    private func waitForPendingAdd(_ id: InputID) async {
        guard let pending = state.withLock({ $0.pending[id] }) else { return }
        _ = try? await pending.task.value
        // El `add` inserta justo después de que termine la tarea.
        for _ in 0..<200 where state.withLock({ $0.pending[id]?.token == pending.token }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func replace(_ entry: Entry, with descriptor: InputDescriptor) async throws {
        let replacement = try await makePreparedSource(for: descriptor)
        let swapped = state.withLock { s -> Bool in
            // Si entretanto se eliminó o se sustituyó por otra edición, se descarta esta.
            guard let index = s.entries.firstIndex(where: { $0.id == entry.id && $0.source === entry.source }) else {
                return false
            }
            s.entries[index] = Entry(id: entry.id, source: replacement, descriptor: descriptor)
            applyVisibilityLocked(&s)
            return true
        }
        guard swapped else {
            Self.discard(replacement)
            throw MediaError.cancelled(entry.id.description)
        }
        if entry.source.playbackState == .playing { replacement.play() }
        Self.discard(entry.source)
    }

    static func needsReplacement(_ old: InputContent, _ new: InputContent) -> Bool {
        switch (old, new) {
        case let (.video(a), .video(b)), let (.image(a), .image(b)):
            a.path != b.path
        case let (.audio(a, va), .audio(b, vb)):
            a.path != b.path || va != vb
        case (.color, .color):
            false
        case let (.playlist(a), .playlist(b)):
            a != b
        default:
            true
        }
    }

    private static func applyInPlace(_ descriptor: InputDescriptor, to source: FrameSource) throws {
        switch (source, descriptor.content) {
        case let (video as VideoInput, _):
            video.setLoop(descriptor.loop)
            video.setInOut(inPoint: descriptor.inPoint, outPoint: descriptor.outPoint)
        case let (audio as AudioInput, _):
            audio.setLoop(descriptor.loop)
            audio.setInOut(inPoint: descriptor.inPoint, outPoint: descriptor.outPoint)
        case let (color as ColorInput, .color(newColor)):
            if color.currentColor != newColor { try color.setColor(newColor) }
        default:
            break
        }
    }

    private static func discard(_ source: FrameSource) {
        source.pause()
        (source as? DecodingControllable)?.setDecodingEnabled(false)
    }

    /// Recalcula y aplica (dentro del cerrojo) qué fuentes decodifican: visibles, y de
    /// vídeo como mucho `maxActiveVideoDecoders`, por orden de alta. Primero
    /// deshabilita y después habilita, para no superar nunca el límite.
    private func applyVisibilityLocked(_ s: inout State) {
        var decoders = 0
        var active = Set<InputID>()
        var enable: [DecodingControllable] = []
        var disable: [DecodingControllable] = []
        for entry in s.entries {
            guard let control = entry.source as? DecodingControllable else { continue }
            var enabled = s.visible?.contains(entry.id) ?? true
            if enabled, control.usesVideoDecoder {
                enabled = decoders < maxActiveVideoDecoders
                if enabled {
                    decoders += 1
                    active.insert(entry.id)
                }
            }
            if enabled { enable.append(control) } else { disable.append(control) }
        }
        s.activeDecoders = active
        disable.forEach { $0.setDecodingEnabled(false) }
        enable.forEach { $0.setDecodingEnabled(true) }
    }
}
