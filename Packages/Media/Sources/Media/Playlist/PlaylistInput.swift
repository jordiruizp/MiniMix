import AVFAudio
import Core
import Foundation
import Metal
import os

/// Entrada de playlist (T70/T71, sección 6 del plan) con dos ranuras A/B.
///
/// - **Secuencia**: `PlaylistSequencer` (Core, máquina 6.3) decide qué suena: enabled, modos
///   Continuo / Parar tras cada item, bucle, `stopAfter`, next/previous/jump/restart y
///   `lastEventRestartsItem`. Cada item reutiliza las entradas sueltas (`VideoInput`,
///   `AudioInput`, `ImageInput`, `ColorInput`).
/// - **Ranuras**: `active` (lo que se ve) y `standby` (el siguiente, `upcomingIndex`,
///   precargado `preloadLead` ≈ 3 s antes del final y con su primer fotograma ya pedido).
///   Al cambiar se intercambian y la saliente se libera tras `releaseDelay` (command buffers
///   en vuelo). **Como máximo 2 items cargados** (`stats.maxLoadedItems`): no se precarga
///   mientras la saliente siga viva.
/// - **Fin de item**: vídeo por su posición (`currentTime`, In/Out, `duration`); imagen,
///   color y audio por `effectiveDuration`/duración del medio, redondeado a fotogramas del
///   `MasterClock`. El cambio se programa en la rejilla de ticks: `texture(for:)` muestra el
///   entrante desde el primer tick ≥ fin, sin negro. El vídeo entrante arranca medio
///   fotograma antes (temporizador de host) para que su fotograma 0 esté en pantalla en
///   ese tick.
/// - **Precarga tardía** (riesgo 11): se mantiene el último fotograma del saliente, se
///   registra en el log y en `stats.lateSwitches`, y se cambia en cuanto esté lista.
/// - **Held** (modo parar / `stopAfter`): estado `.held` con el siguiente cued y precargado;
///   `play()` lo arranca. Lo que se ve lo decide `holdBehavior`.
/// - **Fundido** (`ItemTransition.fade`): el entrante empieza `d` s antes del final del
///   saliente; vídeo con el `Compositor` de Render (`TransitionCurve.videoMix`) y audio con
///   `TransitionCurve.audioGains` en el mezclador propio (`PlaylistAudioMixer`).
/// - **Concurrencia**: todo el control corre en una cola serie (`queue`); los comandos
///   públicos se encolan (asíncronos). `texture(for:)` solo toma el cerrojo corto del estado
///   y, durante un fundido, codifica un command buffer sin esperar.
/// - Ocultar (`setDecodingEnabled(false)`) pausa la decodificación de ambas ranuras y
///   congela la línea de tiempo (no avanza ni cambia de item) sin cambiar `playbackState`.
/// - Eventos: `.itemChanged(id)` (nil al terminar), `.ended`, `.durationKnown(d)` con la
///   duración del item que empieza, `.error` si un item no carga (se salta).
public final class PlaylistInput: FrameSource, AudioSource, DecodingControllable {
    public struct Stats: Sendable, Equatable {
        /// Items con fuente creada y aún no liberada (incluye la precarga en curso).
        public var loadedItems = 0
        public var maxLoadedItems = 0
        /// Fuentes de item creadas en total.
        public var createdItems = 0
        /// Cambios de item (automáticos y manuales).
        public var switches = 0
        /// Cambios que esperaron a una precarga no lista a tiempo (se mantuvo el último fotograma).
        public var lateSwitches = 0
    }

    public let id: InputID
    public let events: AsyncStream<SourceEvent>
    let continuation: AsyncStream<SourceEvent>.Continuation
    let environment: PlaylistEnvironment
    let renderer: PlaylistRenderer
    let mixer = PlaylistAudioMixer()
    let state: LockedState<State>
    let queue: DispatchQueue
    let logger = Logger(subsystem: "MiniMix", category: "Playlist")
    private let tickTask = LockedState<Task<Void, Never>?>(nil)

    /// - Parameters:
    ///   - fit: encaje de los items dentro de la playlist durante los fundidos (fuera del
    ///     fundido se entrega la textura del item y la encaja el compositor de Programa).
    ///   - drivenByClock: si es false no se suscribe a `clock.ticks` (tests: `tick(_:)`).
    public init(id: InputID = InputID(), playlist: Playlist, environment: PlaylistEnvironment,
                fit: FitMode = .fit, drivenByClock: Bool = true) throws {
        self.id = id
        self.environment = environment
        renderer = try PlaylistRenderer(context: environment.context, canvasSize: environment.canvasSize)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
        state = LockedState(State(sequencer: PlaylistSequencer(playlist: playlist), fit: fit,
                                  frameDuration: environment.clock.frameRate.frameDuration))
        queue = DispatchQueue(label: "minimix.playlist.\(id)", qos: .userInteractive)
        if drivenByClock { startTicking() }
        probeDurations(playlist)
    }

    deinit {
        tickTask.withLock { $0?.cancel() }
        continuation.finish()
    }

    /// Fábrica para `InputManager(playlistFactory:)`.
    public static func factory(environment: PlaylistEnvironment) -> InputManager.PlaylistFactory {
        { descriptor in
            guard case .playlist(let playlist) = descriptor.content else {
                throw MediaError.unsupported("\(descriptor.name) no es una playlist")
            }
            return try PlaylistInput(id: descriptor.id, playlist: playlist, environment: environment, fit: descriptor.fit)
        }
    }

    // MARK: FrameSource / AudioSource

    public var node: AVAudioNode? { mixer.node }

    public var nativeSize: PixelSize {
        state.withLock { $0.active?.source.nativeSize } ?? environment.canvasSize
    }

    public var playbackState: PlaybackState {
        state.withLock { s in
            switch s.sequencer.state {
            case .idle: s.prepared ? .paused : .idle
            case .playing: s.userPaused ? .paused : .playing
            case .held: .held
            case .ended: .ended
            }
        }
    }

    /// Carga el primer item habilitado (sin reproducir). Si no carga, se salta al siguiente;
    /// lanza el último error si ninguno carga. Una playlist vacía queda preparada sin textura.
    public func prepare() async throws {
        var lastError: Error?
        while true {
            let next = await onQueue { () -> (FrameSource, Int)? in
                guard !self.state.withLock({ $0.prepared }) else { return nil }
                guard let index = self.state.withLock({ $0.sequencer.upcomingIndex }) else { return nil }
                return self.createSlot(index: index, asActive: true).map { ($0, index) }
            }
            guard let (source, index) = next else { break }
            do {
                try await source.prepare()
                await Self.prewarm(source)
                await onQueue { self.loadFinished(source: source) }
                return
            } catch {
                lastError = error
                await onQueue { self.loadFailed(source: source, index: index, error: error) }
            }
        }
        let prepared = await onQueue { () -> Bool in
            let hasItems = self.state.withLock { $0.sequencer.upcomingIndex != nil || $0.active != nil }
            if !hasItems { self.state.withLock { $0.prepared = true } }
            return self.state.withLock { $0.prepared }
        }
        if !prepared, let lastError { throw lastError }
    }

    public func play() { enqueue { $0.handlePlay() } }
    public func pause() { enqueue { $0.handlePause() } }

    /// Posición dentro del item actual (s desde su In).
    public func seek(to seconds: Double) async {
        await onQueue { self.handleSeek(seconds) }
    }

    /// Posición dentro del item actual (s desde su In), nil sin item.
    public var currentTime: Double? {
        state.withLock { s in s.active.map { elapsed(of: $0, at: getterTime(s)) } }
    }

    // MARK: Control de la playlist

    public func next() { enqueue { $0.navigate(.next) } }
    public func previous() { enqueue { $0.navigate(.previous) } }
    public func jump(to item: ItemID) { enqueue { $0.navigate(.jump(item)) } }
    public func restartItem() { enqueue { $0.navigate(.restartItem) } }

    public var playlist: Playlist { state.withLock { $0.sequencer.playlist } }
    public var sequencerState: SequencerState { state.withLock { $0.sequencer.state } }
    public var currentItemID: ItemID? { state.withLock { $0.sequencer.currentItem?.id } }
    public var upcomingItemID: ItemID? {
        state.withLock { s in s.sequencer.upcomingIndex.map { s.sequencer.playlist.items[$0].id } }
    }

    /// Tiempo restante del item actual (s); nil si su duración aún no se conoce.
    public var itemRemainingTime: Double? {
        state.withLock { s -> Double? in
            guard let slot = s.active, let duration = slot.duration else { return nil }
            return max(0, duration - elapsed(of: slot, at: getterTime(s)))
        }
    }

    /// Tiempo restante hasta el final de la lista (item actual + los habilitados que lo
    /// siguen, sin dar la vuelta del bucle); nil si falta alguna duración.
    public var playlistRemainingTime: Double? {
        guard let item = itemRemainingTime else { return nil }
        return state.withLock { s -> Double? in
            guard let index = s.sequencer.currentIndex else { return nil }
            var total = item
            for following in s.sequencer.playlist.items[(index + 1)...] where following.enabled {
                guard let duration = s.knownDurations[following.id] else { return nil }
                total += duration
            }
            return total
        }
    }

    /// Encaje de los items durante los fundidos.
    public var itemFit: FitMode {
        get { state.withLock { $0.fit } }
        set { state.withLock { $0.fit = newValue } }
    }

    public var stats: Stats { state.withLock { $0.stats } }

    /// Instante de referencia de las consultas: ahora, o el último tick si va por delante.
    private func getterTime(_ s: State) -> HostTime { max(environment.clock.now, s.lastTick ?? .zero) }

    // MARK: DecodingControllable

    public var usesVideoDecoder: Bool {
        state.withLock { s in
            s.sequencer.playlist.items.contains { if case .video = $0.source { $0.enabled } else { false } }
        }
    }

    public func setDecodingEnabled(_ enabled: Bool) {
        // Aplicación inmediata a las fuentes (InputManager decide dentro de su cola) y
        // congelación de la línea de tiempo en la cola de control.
        let sources = state.withLock { s -> [FrameSource] in
            s.decodingEnabled = enabled
            return [s.active, s.standby, s.outgoing].compactMap { $0?.source }
        }
        sources.forEach { ($0 as? DecodingControllable)?.setDecodingEnabled(enabled) }
        enqueue { $0.timelineFrozenChanged() }
    }

    // MARK: Ritmo

    /// Procesa un tick del reloj (lo hace solo la suscripción a `clock.ticks`; público para
    /// integraciones que marquen el ritmo a mano).
    public func tick(_ time: HostTime) { enqueue { $0.step(at: time) } }

    private func startTicking() {
        let clock = environment.clock
        let task = Task.detached(priority: .high) { [weak self] in
            while !Task.isCancelled {
                // stop() termina la suscripción: se vuelve a leer `ticks` tras un start().
                for await time in clock.ticks {
                    guard let self else { return }
                    self.tick(time)
                }
                try? await Task.sleep(for: .milliseconds(50))
                if self == nil { return }
            }
        }
        tickTask.withLock { $0 = task }
    }

    private func probeDurations(_ playlist: Playlist) {
        let environment = environment
        let probe = environment.durationProbe ?? { await environment.probeDuration($0) }
        Task.detached(priority: .utility) { [weak self] in
            for item in playlist.items {
                guard let duration = await probe(item) else { continue }
                self?.state.withLock { s in
                    if s.knownDurations[item.id] == nil { s.knownDurations[item.id] = duration }
                }
            }
        }
    }

    // MARK: Cola de control

    func enqueue(_ body: @escaping @Sendable (PlaylistInput) -> Void) {
        queue.async { [self] in body(self) }
    }

    func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Espera a que la cola de control procese lo encolado.
    func settle() async { await onQueue {} }

    /// Espera a que no haya cargas en curso (tests).
    func waitUntilLoaded(timeout: Double = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await settle()
            if state.withLock({ $0.loading == 0 }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Pide el primer fotograma (vídeo pausado en su In) para que esté listo al cambiar.
    static func prewarm(_ source: FrameSource) async {
        guard source is VideoInput else { return }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if source.texture(for: HostClock.hostTime(nanos: HostClock.nowNanos())) != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
