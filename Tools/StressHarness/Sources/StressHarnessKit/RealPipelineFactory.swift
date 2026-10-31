import Core
import Foundation
import Media
import Metal
import Render

/// Pipeline con los módulos reales (T90): `Media.MasterClock`, `Render.Compositor`,
/// `Core.SwitcherState`, `Core.PlaylistSequencer` y fuentes de Media (`VideoInput`, `ImageInput`,
/// `ColorInput`). Los escenarios de estrés T90 (`LiveScenarioRunner`) usan además `InputManager`
/// con `PlaylistInput`, `AudioEngine` y medios reales de TestMedia a través de `LiveRig`.
public struct RealPipelineFactory: PipelineFactory {
    public let name = "real"
    public let context: MetalContext?
    private let textureCache: VideoTextureCache?
    public var device: MTLDevice? { context?.device }

    public init(context: MetalContext? = MetalContext.shared) {
        self.context = context
        textureCache = context.map { VideoTextureCache(context: $0) }
    }

    public var components: [String: String] {
        ["clock": "Media.MasterClock", "compositor": context == nil ? "none" : "Render.Compositor",
         "switcher": "Core.SwitcherState", "sequencer": "Core.PlaylistSequencer",
         "sources": "Media.VideoInput/ImageInput/ColorInput"]
    }

    public func makeClock(frameRate: FrameRate) -> MasterClockProtocol { MasterClock(frameRate: frameRate) }

    public func makeCompositor() -> Compositing? {
        context.flatMap { try? Compositor(context: $0, pixelFormats: [.bgra8Unorm]) }
    }

    public func makeSwitcher() -> any SwitcherStateMachine { SwitcherState() }
    public func makeSequencer(_ playlist: Playlist) -> any PlaylistSequencing { PlaylistSequencer(playlist: playlist) }

    public func makeSource(id: InputID, content: InputContent, canvas: PixelSize) -> FrameSource {
        guard let context, let textureCache else {
            return MockPipelineFactory(device: nil).makeSource(id: id, content: content, canvas: canvas)
        }
        switch content {
        case .video(let ref):
            return VideoInput(id: id, url: URL(fileURLWithPath: ref.path), textureCache: textureCache, loop: true)
        case .image(let ref):
            let loader = ImageTextureLoader(context: context)
            return ImageInput(id: id, url: URL(fileURLWithPath: ref.path), canvasSize: canvas) { url, size in
                try await loader.loadTexture(from: url, maxSize: size)
            }
        case .color(let color):
            return ColorInput(id: id, color: color, context: context, canvasSize: canvas)
        case .audio, .playlist:
            return ColorInput(id: id, color: .black, context: context, canvasSize: canvas)
        }
    }
}
