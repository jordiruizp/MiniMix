import Audio
import Core
import Foundation
import Media
import Render
import TestSupport

public enum LiveRigError: Error, CustomStringConvertible {
    case noMetal
    case missingTestMedia(String)

    public var description: String {
        switch self {
        case .noMetal: "sin dispositivo Metal"
        case .missingTestMedia(let detail): "TestMedia incompleto (\(detail)); ejecuta Tools/generate-testmedia.sh"
        }
    }
}

/// Montaje de los módulos reales como en la app (`AppServices.live()`, T80): `MetalContext`,
/// `MasterClock`, `InputManager` con `PlaylistInput.factory`, `AudioEngine` con el audio de cada
/// entrada conectado, y las 8 entradas de la sección 10.2 con medios de TestMedia.
public final class LiveRig: @unchecked Sendable {
    // @unchecked: todo es inmutable tras `make` o thread-safe (Media/Audio/Render).
    public struct Input: Sendable, Codable, Equatable {
        public var id: InputID
        public var name: String
        public var file: String?
        /// clipID del código de fotograma (nil en color y playlist).
        public var clipID: Int?
        public var isVideo: Bool
    }

    /// Vídeos de la matriz para las entradas sueltas (ninguno está en `playlist_50`).
    public static let videoFiles = ["video/h264_1080p25.mp4", "video/h264_1080p2997.mp4", "video/hevc_1080p25.mp4",
                                    "video/h264_1080p5994.mp4", "video/prores422_1080p25.mov"]
    public static let imageFile = "image/png_alpha_1920x1080.png"

    public let context: MetalContext
    public let clock: MasterClock
    public let manager: InputManager
    public let audio: AudioEngine?
    public let audioError: String?
    public let inputs: [Input]
    public let playlistID: InputID
    /// clipIDs de los items de la playlist (para reconocer sus fotogramas en Programa).
    public let playlistClipIDs: Set<Int>
    public let playlistItemCount: Int

    private init(context: MetalContext, clock: MasterClock, manager: InputManager, audio: AudioEngine?,
                 audioError: String?, inputs: [Input], playlistID: InputID, playlistClipIDs: Set<Int>, itemCount: Int) {
        self.context = context
        self.clock = clock
        self.manager = manager
        self.audio = audio
        self.audioError = audioError
        self.inputs = inputs
        self.playlistID = playlistID
        self.playlistClipIDs = playlistClipIDs
        playlistItemCount = itemCount
    }

    public var playlist: PlaylistInput? { manager.frameSource(for: playlistID) as? PlaylistInput }

    /// Crea servicios y entradas, conecta el audio y arranca la reproducción de todas las fuentes.
    public static func make(canvas: CanvasFormat) async throws -> LiveRig {
        guard TestMediaLocator.isGenerated else { throw LiveRigError.missingTestMedia("sin checksums.sha256") }
        let manifest = try TestMediaLocator.manifest()
        guard let context = MetalContext.shared else { throw LiveRigError.noMetal }
        let clock = MasterClock(frameRate: canvas.frameRate)
        let environment = PlaylistEnvironment(context: context, clock: clock, canvasSize: canvas.size)
        let manager = InputManager(context: context, canvasSize: canvas.size,
                                   playlistFactory: PlaylistInput.factory(environment: environment))
        var audio: AudioEngine?
        var audioError: String?
        do {
            let engine = try AudioEngine()
            // Como `AppServices.live()`: del tick al vsync, un fotograma (retrasa las entradas `.playerTap`).
            engine.videoPresentationLatency = canvas.frameRate.frameDuration
            // Como la App: el motor ya suena cuando se añaden las entradas (attach en marcha, #19).
            try engine.start()
            audio = engine
        } catch {
            audioError = "\(error)"
        }

        func clip(_ file: String) throws -> Int? {
            guard let entry = manifest.file(file) else { throw LiveRigError.missingTestMedia(file) }
            guard FileManager.default.fileExists(atPath: entry.url.path) else { throw LiveRigError.missingTestMedia(file) }
            return entry.frameCode?.clipID
        }

        var descriptors: [(InputDescriptor, Input)] = []
        for file in videoFiles {
            let desc = InputDescriptor(name: file, content: .video(MediaReference(path: TestMediaLocator.url(file).path)),
                                       loop: true)
            descriptors.append((desc, Input(id: desc.id, name: file, file: file, clipID: try clip(file), isVideo: true)))
        }
        let image = InputDescriptor(name: imageFile, content: .image(MediaReference(path: TestMediaLocator.url(imageFile).path)))
        descriptors.append((image, Input(id: image.id, name: imageFile, file: imageFile, clipID: try clip(imageFile),
                                         isVideo: false)))
        let color = InputDescriptor(name: "color", content: .color(RGBAColor(red: 0.1, green: 0.3, blue: 0.8)))
        descriptors.append((color, Input(id: color.id, name: "color", file: nil, clipID: nil, isVideo: false)))

        guard let set = manifest.set("playlist_50") else { throw LiveRigError.missingTestMedia("set playlist_50") }
        let (items, clipIDs) = try playlistItems(set, clip: clip)
        let playlist = InputDescriptor(name: "playlist_50", content: .playlist(Playlist(items: items, loop: true)))
        descriptors.append((playlist, Input(id: playlist.id, name: "playlist_50", file: nil, clipID: nil, isVideo: true)))

        for (descriptor, _) in descriptors {
            try await manager.add(descriptor)
            if let audio, let source = manager.audioSource(for: descriptor.id) {
                // Igual que LiveInputs: perfil antes del attach, aviso de salida después.
                let frameSource = manager.frameSource(for: descriptor.id)
                let tapped = frameSource is VideoInput || frameSource is PlaylistInput
                audio.setSyncProfile(tapped ? .playerTap : .direct, for: descriptor.id)
                try? audio.attach(source)
                (frameSource as? VideoInput)?.audioOutputDidChange()
                audio.setAudioFollowsProgram(true, for: descriptor.id)
            }
            manager.frameSource(for: descriptor.id)?.play()
        }
        return LiveRig(context: context, clock: clock, manager: manager, audio: audio, audioError: audioError,
                       inputs: descriptors.map(\.1), playlistID: playlist.id, playlistClipIDs: clipIDs,
                       itemCount: items.count)
    }

    /// Items de `playlist_50` y los clipIDs de sus vídeos/imágenes.
    private static func playlistItems(_ set: TestMediaManifest.MediaSet,
                                      clip: (String) throws -> Int?) throws -> ([PlaylistItem], Set<Int>) {
        var clipIDs = Set<Int>()
        let items = try set.items.map { item -> PlaylistItem in
            switch item.type {
            case "video", "image":
                let file = item.file ?? ""
                if let id = try clip(file) { clipIDs.insert(id) }
                let ref = MediaReference(path: TestMediaLocator.url(file).path)
                return PlaylistItem(source: item.type == "video" ? .video(ref) : .image(ref), duration: item.duration)
            default:
                let color = item.color.map { RGBAColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
                return PlaylistItem(source: .color(color ?? .black), duration: item.duration ?? 2)
            }
        }
        return (items, clipIDs)
    }

    public func tearDown() {
        clock.stop()
        playlist?.teardown()
        audio?.stop()
        for input in inputs { manager.frameSource(for: input.id)?.pause() }
    }
}
