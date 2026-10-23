// Core/Contracts.swift — contratos congelados de MiniMix (contracts-v1).
//
// Propiedad: ORQUESTADOR. Ningún subagente modifica este archivo.
// Para pedir un cambio: descríbelo en el informe final; el orquestador decide,
// versiona (contracts-vN) y avisa a los afectados.
//
// Organización:
//   1. Tipos base (IDs, tiempo, formato)                    — Swift puro
//   2. Modelos de datos (Input, Playlist, Project)          — Swift puro, Codable
//   3. Switcher (Command, Effect, transiciones)             — Swift puro
//   4. Playlist: secuenciador (máquina de estados 6.3)      — Swift puro
//   5. Fuentes y servicios de GPU/audio                     — solo con Metal/AVFAudio
//
// Las secciones 1–4 compilan en Linux (Core debe ser 100 % testeable sin
// AVFoundation ni Metal). La sección 5 está tras `#if canImport(...)`.

import Foundation

// MARK: - 1. Tipos base

/// Identificador estable de una entrada del switcher.
public struct InputID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Identificador estable de un item de playlist.
public struct ItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Instante en la base de tiempo del host (segundos, monotónico).
/// Lo produce el `MasterClock` (Media); Core solo lo transporta y compara.
public struct HostTime: Hashable, Comparable, Codable, Sendable {
    public var seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public static let zero = HostTime(seconds: 0)
    public static func < (lhs: HostTime, rhs: HostTime) -> Bool { lhs.seconds < rhs.seconds }
    public static func + (lhs: HostTime, rhs: Double) -> HostTime { HostTime(seconds: lhs.seconds + rhs) }
    public static func - (lhs: HostTime, rhs: HostTime) -> Double { lhs.seconds - rhs.seconds }
}

/// Frecuencia de fotogramas racional (p. ej. 30000/1001 = 29,97).
public struct FrameRate: Hashable, Codable, Sendable {
    public var numerator: Int
    public var denominator: Int
    public init(_ numerator: Int, _ denominator: Int = 1) {
        self.numerator = numerator
        self.denominator = denominator
    }
    public var fps: Double { Double(numerator) / Double(denominator) }
    public var frameDuration: Double { Double(denominator) / Double(numerator) }

    public static let fps25 = FrameRate(25)
    public static let fps29_97 = FrameRate(30000, 1001)
    public static let fps30 = FrameRate(30)
    public static let fps50 = FrameRate(50)
    public static let fps59_94 = FrameRate(60000, 1001)
    public static let fps60 = FrameRate(60)
}

/// Tamaño entero en píxeles (Core no depende de CoreGraphics).
public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    public static let hd720 = PixelSize(width: 1280, height: 720)
    public static let hd1080 = PixelSize(width: 1920, height: 1080)
    /// Experimental en MacBook Neo.
    public static let uhd4K = PixelSize(width: 3840, height: 2160)
}

/// Formato del lienzo de Programa.
public struct CanvasFormat: Hashable, Codable, Sendable {
    public var size: PixelSize
    public var frameRate: FrameRate
    public init(size: PixelSize = .hd1080, frameRate: FrameRate = .fps60) {
        self.size = size
        self.frameRate = frameRate
    }
}

/// Color RGBA lineal en 0…1.
public struct RGBAColor: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

/// Cómo se encaja una fuente en el lienzo.
public enum FitMode: String, Codable, Sendable, CaseIterable {
    case fit, fill, stretch
}

// MARK: - 2. Modelos de datos

/// Referencia a un archivo de medios. `bookmark` contiene un security-scoped
/// bookmark (lo crea/resuelve Persistence); `path` es informativo y sirve
/// para el reenlace de archivos perdidos.
public struct MediaReference: Hashable, Codable, Sendable {
    public var path: String
    public var bookmark: Data?
    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }
}

public enum InputKind: String, Codable, Sendable, CaseIterable {
    case video, audio, image, color, playlist
}

/// Qué muestra un item/entrada de solo audio.
public enum AudioVisual: Hashable, Codable, Sendable {
    case black
    /// Playlist: mantener la última imagen visible.
    case lastImage
    /// Imagen de cartela.
    case card(MediaReference)
}

/// Contenido de una entrada. El `InputKind` se deriva de aquí.
public enum InputContent: Hashable, Codable, Sendable {
    case video(MediaReference)
    case audio(MediaReference, visual: AudioVisual)
    case image(MediaReference)
    case color(RGBAColor)
    case playlist(Playlist)

    public var kind: InputKind {
        switch self {
        case .video: .video
        case .audio: .audio
        case .image: .image
        case .color: .color
        case .playlist: .playlist
        }
    }
}

/// Descripción persistente de una entrada (lo que se guarda en .minimix).
public struct InputDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: InputID
    public var name: String
    public var content: InputContent
    public var loop: Bool
    /// Recortes en segundos (vídeo/audio).
    public var inPoint: Double?
    public var outPoint: Double?
    public var fit: FitMode
    /// Ganancia lineal 0…2 (1 = 0 dB).
    public var volume: Float
    public var muted: Bool
    /// Si true, el audio solo suena cuando la entrada está en Programa.
    public var audioFollowsProgram: Bool

    public init(
        id: InputID = InputID(),
        name: String,
        content: InputContent,
        loop: Bool = false,
        inPoint: Double? = nil,
        outPoint: Double? = nil,
        fit: FitMode = .fit,
        volume: Float = 1,
        muted: Bool = false,
        audioFollowsProgram: Bool = true
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.loop = loop
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.fit = fit
        self.volume = volume
        self.muted = muted
        self.audioFollowsProgram = audioFollowsProgram
    }

    public var kind: InputKind { content.kind }
}

// Playlist (sección 6.2 del plan)

public enum PlaybackMode: String, Codable, Sendable, CaseIterable {
    case continuous, stopAfterEach
}

public enum HoldBehavior: String, Codable, Sendable, CaseIterable {
    case lastFrame, black, nextFirstFrame
}

public enum ItemTransition: Hashable, Codable, Sendable {
    case cut
    /// 0…2 s.
    case fade(seconds: Double)
}

public enum ItemSource: Hashable, Codable, Sendable {
    case video(MediaReference)
    case audio(MediaReference)
    case image(MediaReference)
    case color(RGBAColor)
}

public struct PlaylistItem: Identifiable, Hashable, Codable, Sendable {
    public let id: ItemID
    public var source: ItemSource
    /// Obligatoria en imagen y color (por defecto 10 s); en vídeo/audio, nil = duración del archivo.
    public var duration: Double?
    public var inPoint: Double?
    public var outPoint: Double?
    public var stopAfter: Bool
    public var enabled: Bool

    public init(
        id: ItemID = ItemID(),
        source: ItemSource,
        duration: Double? = nil,
        inPoint: Double? = nil,
        outPoint: Double? = nil,
        stopAfter: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.source = source
        self.duration = duration
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.stopAfter = stopAfter
        self.enabled = enabled
    }

    public static let defaultStillDuration: Double = 10
}

public struct Playlist: Hashable, Codable, Sendable {
    public var items: [PlaylistItem]
    public var mode: PlaybackMode
    public var loop: Bool
    public var holdBehavior: HoldBehavior
    public var itemTransition: ItemTransition
    /// Qué muestran los items de audio.
    public var audioItemVisual: AudioVisual

    public init(
        items: [PlaylistItem] = [],
        mode: PlaybackMode = .continuous,
        loop: Bool = false,
        holdBehavior: HoldBehavior = .lastFrame,
        itemTransition: ItemTransition = .cut,
        audioItemVisual: AudioVisual = .black
    ) {
        self.items = items
        self.mode = mode
        self.loop = loop
        self.holdBehavior = holdBehavior
        self.itemTransition = itemTransition
        self.audioItemVisual = audioItemVisual
    }
}

/// Documento .minimix (JSON). `schemaVersion` lo gestionan Core (T10) y
/// Persistence (migraciones, T82).
public struct Project: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var canvas: CanvasFormat
    public var inputs: [InputDescriptor]
    public var preview: InputID?
    public var program: InputID?
    public var defaultFadeDuration: Double
    public var masterVolume: Float

    public init(
        schemaVersion: Int = Project.currentSchemaVersion,
        canvas: CanvasFormat = CanvasFormat(),
        inputs: [InputDescriptor] = [],
        preview: InputID? = nil,
        program: InputID? = nil,
        defaultFadeDuration: Double = 1,
        masterVolume: Float = 1
    ) {
        self.schemaVersion = schemaVersion
        self.canvas = canvas
        self.inputs = inputs
        self.preview = preview
        self.program = program
        self.defaultFadeDuration = defaultFadeDuration
        self.masterVolume = masterVolume
    }
}

// MARK: - 3. Switcher

public enum TransitionKind: String, Codable, Sendable, CaseIterable {
    case cut, fade
    /// v1.1 (opcional).
    case wipe
}

public enum TransitionState: Hashable, Sendable {
    case idle
    /// `progress` 0…1 (0 = todo `program`, 1 = todo `preview`).
    case running(kind: TransitionKind, progress: Double)
}

/// Estado de reproducción de una fuente.
public enum PlaybackState: Hashable, Sendable {
    case idle, playing, paused, ended
    /// Playlist parada tras un item (sección 6.3).
    case held
}

/// Comandos de la interfaz (y en el futuro MIDI/Stream Deck).
public enum Command: Hashable, Codable, Sendable {
    // Buses y transiciones
    case selectPreview(InputID)
    case cut
    /// Duración 0,1…5 s.
    case fade(duration: Double)
    /// Posición absoluta de la T-bar 0…1. Al llegar a 1 se completa la transición.
    case tbar(Double)
    // Transporte
    case play(InputID)
    case pause(InputID)
    case restart(InputID)
    case seek(InputID, seconds: Double)
    case setLoop(InputID, Bool)
    // Audio
    case setVolume(InputID, Float)
    case setMute(InputID, Bool)
    case setSolo(InputID, Bool)
    case setAudioFollowsProgram(InputID, Bool)
    case setMasterVolume(Float)
    // Playlist
    case playlistNext(InputID)
    case playlistPrevious(InputID)
    case playlistJump(InputID, ItemID)
}

/// Efectos que produce la máquina de estados del switcher y que ejecuta la
/// capa de integración (App/T80) sobre Media, Render y Audio.
public enum Effect: Hashable, Sendable {
    /// Cambió la asignación de buses (tras cut o al completar una transición).
    case busesChanged(preview: InputID?, program: InputID?)
    case transitionStarted(kind: TransitionKind, from: InputID?, to: InputID?, duration: Double?)
    case transitionProgress(Double)
    case transitionCompleted
    /// Se reenvían a la fuente correspondiente.
    case forward(Command)
}

/// Curva compartida por vídeo y audio (T41: «curva de fundido igual a la de vídeo»).
public enum TransitionCurve {
    /// Mezcla de vídeo para un progreso lineal 0…1 (smoothstep).
    public static func videoMix(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return p * p * (3 - 2 * p)
    }
    /// Ganancias (saliente, entrante) de igual potencia sobre la misma curva.
    public static func audioGains(_ progress: Double) -> (outgoing: Double, incoming: Double) {
        let m = videoMix(progress)
        return (cos(m * .pi / 2), sin(m * .pi / 2))
    }
}

/// Máquina de estados PVW/PGM. Implementación: `SwitcherState` (A · T11).
public protocol SwitcherStateMachine: Sendable {
    var preview: InputID? { get }
    var program: InputID? { get }
    var transition: TransitionState { get }
    /// Aplica un comando. Los comandos no relacionados con buses se devuelven como `.forward`.
    mutating func apply(_ cmd: Command, at time: HostTime) -> [Effect]
    /// Avanza las transiciones temporizadas (fade). Se llama una vez por tick del MasterClock.
    mutating func tick(at time: HostTime) -> [Effect]
}

// MARK: - 4. Playlist: secuenciador

public enum SequencerState: Hashable, Sendable {
    case idle
    case playing(index: Int)
    case held(index: Int, cued: Int?)
    case ended
}

public enum SequencerEvent: Hashable, Sendable {
    case play
    case itemEnded
    case next
    case previous
    case jump(ItemID)
    case restartItem
}

/// Máquina de estados de la sección 6.3. Implementación: `PlaylistSequencer` (A · T12).
/// Solo considera items con `enabled == true`.
public protocol PlaylistSequencing: Sendable {
    var playlist: Playlist { get set }
    var state: SequencerState { get }
    /// Índice que sonará después del actual (para la precarga A/B), si lo hay.
    var upcomingIndex: Int? { get }
    mutating func handle(_ event: SequencerEvent) -> SequencerState
}

// MARK: - 5. Fuentes y servicios (GPU / audio)

/// Eventos asíncronos de una fuente.
public enum SourceEvent: Hashable, Sendable {
    case ended
    case error(String)
    case durationKnown(Double)
    /// Playlist: cambió el item actual.
    case itemChanged(ItemID?)
}

/// Información de diagnóstico del render (barra de estado).
public struct RenderStats: Hashable, Sendable {
    public var fps: Double
    public var droppedFrames: Int
    public var gpuTimeMs: Double
    public init(fps: Double = 0, droppedFrames: Int = 0, gpuTimeMs: Double = 0) {
        self.fps = fps
        self.droppedFrames = droppedFrames
        self.gpuTimeMs = gpuTimeMs
    }
}

/// Reloj maestro (Media · T30). Marca el ritmo de vídeo y audio.
public protocol MasterClockProtocol: AnyObject, Sendable {
    var frameRate: FrameRate { get }
    var now: HostTime { get }
    /// Un valor por fotograma del proyecto, alineado a la rejilla de fotogramas.
    var ticks: AsyncStream<HostTime> { get }
    func start()
    func stop()
}

/// Gestión de servicios de audio (Audio · T40/T41).
public protocol AudioMixing: AnyObject, Sendable {
    func setVolume(_ volume: Float, for input: InputID)
    func setMute(_ muted: Bool, for input: InputID)
    func setSolo(_ solo: Bool, for input: InputID)
    func setAudioFollowsProgram(_ follows: Bool, for input: InputID)
    func setMasterVolume(_ volume: Float)
    /// Aplica el fundido de audio de una transición con `TransitionCurve.audioGains`.
    func transition(from: InputID?, to: InputID?, progress: Double)
    /// Niveles (dBFS pico por canal) ~30 Hz para los vúmetros; `nil` = Master.
    var meters: AsyncStream<[InputID?: [Float]]> { get }
}

/// Persistencia de proyectos (Persistence · T82).
public protocol ProjectStoring: Sendable {
    func save(_ project: Project, to url: URL) throws
    func load(from url: URL) throws -> Project
    /// Referencias que no se pudieron resolver (para el diálogo de reenlace).
    func unresolvedReferences(in project: Project) -> [MediaReference]
}

/// Salida de Programa en pantalla externa (Output · T81).
public struct DisplayInfo: Hashable, Sendable, Identifiable {
    public let id: UInt32 // CGDirectDisplayID
    public var name: String
    public var size: PixelSize
    public var isBuiltIn: Bool
    public init(id: UInt32, name: String, size: PixelSize, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.size = size
        self.isBuiltIn = isBuiltIn
    }
}

@MainActor
public protocol OutputPresenting: AnyObject {
    var displays: [DisplayInfo] { get }
    var activeDisplay: DisplayInfo.ID? { get }
    func show(on display: DisplayInfo.ID)
    func hide()
    /// Cambios de conexión de pantallas.
    var displayChanges: AsyncStream<[DisplayInfo]> { get }
}

#if canImport(Metal)
import Metal

/// Fuente de vídeo para el compositor (Media, Render, Playlist).
/// `texture(for:)` se llama desde el hilo de render: no debe bloquear.
public protocol FrameSource: AnyObject, Sendable {
    var id: InputID { get }
    var nativeSize: PixelSize { get }
    /// Carga/precarga (decodificador, textura en caché…).
    func prepare() async throws
    /// Textura a mostrar en `time`; nil = transparente/negro.
    func texture(for time: HostTime) -> MTLTexture?
    func play()
    func pause()
    func seek(to seconds: Double) async
    var playbackState: PlaybackState { get }
    var events: AsyncStream<SourceEvent> { get }
}

/// Entrada al compositor para un fotograma: `a` = Programa, `b` = Preview/entrante.
public struct CompositorFrame {
    public let a: MTLTexture?
    public let b: MTLTexture?
    /// 0 = solo `a`, 1 = solo `b` (ya pasado por `TransitionCurve.videoMix`).
    public let mix: Float
    public let kind: TransitionKind
    public let fitA: FitMode
    public let fitB: FitMode
    public init(a: MTLTexture?, b: MTLTexture?, mix: Float, kind: TransitionKind,
                fitA: FitMode = .fit, fitB: FitMode = .fit) {
        self.a = a
        self.b = b
        self.mix = mix
        self.kind = kind
        self.fitA = fitA
        self.fitB = fitB
    }
}

/// Compositor Metal (Render · T21).
public protocol Compositing: AnyObject, Sendable {
    var device: MTLDevice { get }
    /// Codifica la composición en `target` (tamaño del lienzo) sin esperar a la GPU.
    func encode(_ frame: CompositorFrame, into target: MTLTexture, commandBuffer: MTLCommandBuffer)
}
#endif

#if canImport(AVFAudio)
import AVFAudio

/// Fuente de audio (Media). AudioEngine conecta `node` a su canal.
public protocol AudioSource: AnyObject, Sendable {
    var id: InputID { get }
    var node: AVAudioNode? { get }
}
#endif

#if canImport(Metal) && canImport(AVFAudio)
/// Alta/baja de entradas y pausa de las no visibles (Media · T32).
public protocol InputManaging: AnyObject, Sendable {
    func add(_ descriptor: InputDescriptor) async throws
    func remove(_ id: InputID) async
    func frameSource(for id: InputID) -> FrameSource?
    func audioSource(for id: InputID) -> AudioSource?
    /// Entradas visibles (PVW, PGM y las que se transicionan). El resto se pausa.
    func setVisible(_ ids: Set<InputID>)
}
#endif
