import Core
import Metal
@testable import MiniMixUI
import Render
import Testing

/// T80 · Aceptación: sesión de conmutación completa con los módulos reales
/// (SwitcherState + InputManager + Compositor + AudioEngine), leyendo los píxeles que salen
/// por los feeds de Programa y Preview.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct LiveSessionTests {
    let red = RGBAColor(red: 1, green: 0, blue: 0)
    let green = RGBAColor(red: 0, green: 1, blue: 0)
    let blue = RGBAColor(red: 0, green: 0, blue: 1)

    struct Session {
        let app: AppViewModel
        let runtime: LiveRuntime
        let ids: [InputID]
    }

    @MainActor final class BusRecorder {
        var states: [BusState] = []
    }

    func makeSession(recorder: BusRecorder? = nil) async throws -> Session {
        let inputs = [red, green, blue].enumerated().map { index, color in
            InputDescriptor(name: "C\(index + 1)", content: .color(color))
        }
        let project = Project(canvas: CanvasFormat(size: PixelSize(width: 64, height: 36), frameRate: .fps60),
                              inputs: inputs, preview: nil, program: inputs[0].id)
        var (services, runtime) = try AppServices.live(project: project)
        if let recorder {
            let original = services.busStateSink
            services.busStateSink = { original?($0); recorder.states.append($0) }
        }
        let app = AppViewModel(services: services)
        await app.registerAllInputs()
        app.publishBusState()
        return Session(app: app, runtime: runtime, ids: inputs.map(\.id))
    }

    /// Renderiza un fotograma y devuelve el píxel central (BGRA) de Programa y Preview.
    func frame(_ runtime: LiveRuntime, at time: HostTime) async throws -> (program: [UInt8], preview: [UInt8]) {
        let renderer = runtime.renderer
        let buffer = try #require(renderer.render(at: time))
        // Sondeo (compatible con el SDK del CI): espera a que la GPU termine el fotograma.
        let deadline = ContinuousClock.now + .seconds(5)
        while buffer.status != .completed, buffer.status != .error {
            guard ContinuousClock.now < deadline else {
                Issue.record("la GPU no terminó el fotograma en 5 s")
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let program = try #require(renderer.programFeed.currentTexture)
        let preview = try #require(renderer.previewFeed.currentTexture)
        return (try await centerPixel(program, runtime.context), try await centerPixel(preview, runtime.context))
    }

    func centerPixel(_ texture: MTLTexture, _ context: MetalContext) async throws -> [UInt8] {
        let buffer = try #require(context.device.makeBuffer(length: 4, options: .storageModeShared))
        let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: texture.width / 2, y: texture.height / 2, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        await withCheckedContinuation { cont in
            commandBuffer.addCompletedHandler { _ in cont.resume() }
            commandBuffer.commit()
        }
        let bytes = buffer.contents().bindMemory(to: UInt8.self, capacity: 4)
        return [bytes[2], bytes[1], bytes[0]] // RGB
    }

    func close(_ pixel: [UInt8], _ expected: [UInt8], tolerance: Int = 3) -> Bool {
        zip(pixel, expected).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    @Test func fullSwitchingSession() async throws {
        let session = try await makeSession()
        let (app, runtime, ids) = (session.app, session.runtime, session.ids)
        defer { runtime.stop() }
        let t0 = runtime.clock.now

        // Arranque: rojo en Programa, Preview vacío (negro).
        var px = try await frame(runtime, at: t0)
        #expect(close(px.program, [255, 0, 0]))
        #expect(close(px.preview, [0, 0, 0]))

        // 2 → Preview; Cut.
        app.send(.selectPreview(ids[1]))
        px = try await frame(runtime, at: t0 + 0.02)
        #expect(close(px.preview, [0, 255, 0]))
        app.send(.cut)
        px = try await frame(runtime, at: t0 + 0.04)
        #expect(close(px.program, [0, 255, 0]))
        #expect(close(px.preview, [255, 0, 0]), "tras el cut se intercambian PVW/PGM")

        // Fade de 1 s: a mitad, mezcla 50 % (smoothstep(0,5) = 0,5); al final, rojo en Programa.
        let fadeStart = runtime.clock.now
        app.send(.fade(duration: 1))
        app.tick(at: fadeStart + 0.5)
        px = try await frame(runtime, at: fadeStart + 0.5)
        #expect(close(px.program, [128, 128, 0], tolerance: 6), "mitad del fundido: \(px.program)")
        app.tick(at: fadeStart + 1.05)
        px = try await frame(runtime, at: fadeStart + 1.05)
        #expect(close(px.program, [255, 0, 0]))
        #expect(close(px.preview, [0, 255, 0]))

        // T-bar manual con 3 → Preview: 25 %, soltar a medias, completar con 1.
        app.send(.selectPreview(ids[2]))
        app.moveTBar(to: 0.25)
        px = try await frame(runtime, at: runtime.clock.now)
        let expected25 = UInt8((255 * TransitionCurve.videoMix(0.25)).rounded())
        #expect(close(px.program, [255 - expected25, 0, expected25], tolerance: 6), "T-bar 25 %: \(px.program)")
        app.moveTBar(to: 1)
        app.releaseTBar()
        px = try await frame(runtime, at: runtime.clock.now)
        #expect(close(px.program, [0, 0, 255]))
        #expect(app.tbarPosition == 0, "la palanca se rearma a 0")

        // T-bar cancelada (vuelta a 0): Programa no cambia.
        app.moveTBar(to: 0.6)
        app.moveTBar(to: 0)
        app.releaseTBar()
        px = try await frame(runtime, at: runtime.clock.now)
        #expect(close(px.program, [0, 0, 255]))
        #expect(app.project.program == ids[2])
        #expect(runtime.renderer.renderedFrames >= 8)
    }

    @Test func fitChangeReachesRenderer() async throws {
        let session = try await makeSession()
        let (app, runtime, ids) = (session.app, session.runtime, session.ids)
        defer { runtime.stop() }
        app.send(.setFit(ids[0], .fill))
        #expect(runtime.renderer.bus.fits[ids[0]] == .fill)
    }

    /// B3: al completar una transición no se publica un estado intermedio (sin transición y
    /// con el Programa antiguo), que el render compondría como un fotograma de la saliente.
    @Test func noIntermediateBusStateOnCompletion() async throws {
        let recorder = BusRecorder()
        let session = try await makeSession(recorder: recorder)
        let (app, runtime, ids) = (session.app, session.runtime, session.ids)
        defer { runtime.stop() }
        app.send(.selectPreview(ids[1]))
        let start = runtime.clock.now
        app.send(.fade(duration: 1))
        app.tick(at: start + 0.5)
        recorder.states.removeAll()
        app.tick(at: start + 1.1)
        let published = recorder.states
        #expect(!published.isEmpty)
        #expect(!published.contains { $0.transition == nil && $0.program == ids[0] },
                "estado intermedio publicado: \(published)")
        #expect(published.last?.program == ids[1])
        #expect(published.last?.transition == nil)
    }
}
