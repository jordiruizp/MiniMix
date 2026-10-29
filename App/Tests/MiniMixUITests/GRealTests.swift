import Core
import CoreMocks
import Foundation
@testable import MiniMixUI
import Persistence
import Testing

/// Ola 2 · G-real: comportamiento de la UI con los contratos de los módulos reales (sin GPU).
@Suite("G-real")
@MainActor
struct GRealTests {
    private func harness(_ manager: TestInputManager,
                         configure: (@MainActor (inout AppServices) -> Void)? = nil) -> Harness {
        Harness(configure: { services in
            services.inputs = manager
            services.simulatesPlayback = false
            configure?(&services)
        })
    }

    // MARK: 1 · Eventos de fuente

    @Test func durationErrorAndEndEventsReachTheUI() async throws {
        let manager = TestInputManager()
        let h = harness(manager)
        await h.app.registerAllInputs()
        let source = try #require(manager.testSource(h.video))
        h.app.updateInput(h.video) { $0.inPoint = 5 }
        source.emit(.durationKnown(40)) // útil (con In = 5) → archivo de 45 s
        #expect(await eventually { h.app.mediaDurations["/tmp/clip.mov"] == 45 })
        source.emit(.error("decodificador perdido"))
        #expect(await eventually { h.app.errorMessage?.contains("decodificador perdido") == true })
        h.app.send(.play(h.video))
        source.emit(.ended)
        #expect(await eventually { h.app.playback[h.video]?.state == .ended })
    }

    @Test func endedIsIgnoredWhenLooping() async throws {
        let manager = TestInputManager()
        let h = harness(manager)
        await h.app.registerAllInputs()
        h.app.send(.setLoop(h.video, true))
        h.app.send(.play(h.video))
        manager.testSource(h.video)?.emit(.ended)
        manager.testSource(h.video)?.emit(.error("marca"))
        #expect(await eventually { h.app.errorMessage != nil })
        #expect(h.app.playback[h.video]?.state == .playing)
    }

    @Test func remainingUsesRealPosition() async throws {
        let manager = TestInputManager()
        let h = harness(manager)
        await h.app.registerAllInputs()
        let source = try #require(manager.testSource(h.video))
        source.setPosition(30) // /tmp/clip.mov dura 95 s en los mocks
        #expect(h.app.remaining(for: h.video) == 65)
        h.app.updateInput(h.video) { $0.outPoint = 60 }
        #expect(h.app.remaining(for: h.video) == 30)
    }

    @Test func resubscribesWhenUpdateReplacesTheSource() async throws {
        let manager = TestInputManager(replaceOnUpdate: true)
        let h = harness(manager)
        await h.app.registerAllInputs()
        let old = try #require(manager.testSource(h.color))
        h.app.setColor(RGBAColor(red: 1, green: 0, blue: 0), for: h.color)
        #expect(await eventually { manager.testSource(h.color) !== old })
        #expect(await eventually { h.app.sourceSubscriptions[h.color]?.source == ObjectIdentifier(manager.testSource(h.color)!) })
        manager.testSource(h.color)?.emit(.error("nueva"))
        #expect(await eventually { h.app.errorMessage?.contains("nueva") == true })
    }

    // MARK: 2 · Playlists

    @Test func playlistsDisabledWithoutFactory() {
        let h = harness(TestInputManager()) { $0.supportsPlaylists = false }
        let count = h.project.inputs.count
        #expect(h.app.playlistsUnavailableReason != nil)
        h.app.addPlaylistInput()
        #expect(h.project.inputs.count == count)
        #expect(h.app.errorMessage != nil)
    }

    @Test func itemChangedFromSourceIsMirrored() async throws {
        let manager = TestInputManager()
        let h = harness(manager)
        await h.app.registerAllInputs()
        h.app.send(.play(h.playlist))
        let items = try #require(h.app.playlists.playlist(for: h.playlist)?.items)
        manager.testSource(h.playlist)?.emit(.itemChanged(items[2].id))
        #expect(await eventually { h.app.playlists.currentIndex(for: h.playlist) == 2 })
    }

    // MARK: 3 · Persistencia

    @Test func saveAdoptsWrittenProjectAndOpenActivates() async throws {
        let bookmark = Data([1, 2, 3])
        let activated = Box<[Project]>([])
        let store = MockProjectStore()
        let h = harness(TestInputManager()) { services in
            services.store = store
            services.writeProject = { project, url in
                let stored = Project(canvas: project.canvas, inputs: project.inputs.map { input in
                    var copy = input
                    if case .image(let ref) = input.content {
                        copy.content = .image(MediaReference(path: ref.path, bookmark: bookmark))
                    }
                    return copy
                }, preview: project.preview, program: project.program)
                try store.save(stored, to: url)
                return stored
            }
            services.activateProject = { activated.value.append($0) }
        }
        let url = URL(fileURLWithPath: "/tmp/g-real.minimix")
        h.app.saveProject(to: url)
        #expect(h.input(2).content.mediaReference?.bookmark == bookmark)
        await h.app.openProject(from: url)
        #expect(activated.value.count == 1)
        #expect(activated.value.first?.inputs.map(\.id) == h.project.inputs.map(\.id))
    }

    @Test func relinkMissingFilesFromFolder() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("relink-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        for name in ["a.png", "b.png"] { try Data([0]).write(to: folder.appendingPathComponent(name)) }
        let gone = "/nonexistent-\(UUID().uuidString)"
        let project = Project(inputs: [
            InputDescriptor(name: "A", content: .image(MediaReference(path: "\(gone)/a.png"))),
            InputDescriptor(name: "B", content: .image(MediaReference(path: "\(gone)/b.png")))
        ])
        let store = ProjectStore(bookmarkMode: .plain)
        let h = Harness(project: project, configure: { services in
            services.inputs = TestInputManager()
            services.store = store
            services.relinkProject = { reference, url, project, folder in
                let result = try store.relinkReporting(reference, to: url, in: project, searchingIn: folder)
                return RelinkOutcome(project: result.project, relinkedPaths: result.relinkedPaths,
                                     stillUnresolved: result.stillUnresolved)
            }
        })
        let file = folder.appendingPathComponent("p.minimix")
        h.app.saveProject(to: file)
        await h.app.openProject(from: file)
        #expect(h.app.missingReferences.count == 2)
        let relinked = await h.app.relinkMissing(in: folder)
        #expect(relinked == 2)
        #expect(h.app.missingReferences.isEmpty)
        let paths = h.project.inputs.compactMap { $0.content.mediaReference?.path }
        #expect(paths.count == 2 && paths.allSatisfy { $0.contains(folder.lastPathComponent) })
    }

    // MARK: 4 · Edición en directo

    @Test func liveEditsUseUpdateNotRemoveAdd() async throws {
        let manager = TestInputManager()
        let h = harness(manager)
        await h.app.registerAllInputs()
        let adds = manager.log.current.adds.count
        h.app.send(.setLoop(h.video, true))
        h.app.send(.setFit(h.image, .fill))
        h.app.setTrim(inPoint: 2, outPoint: 9, for: h.video)
        h.app.setColor(RGBAColor(red: 0, green: 1, blue: 0), for: h.color)
        #expect(await eventually { manager.log.current.updates.count == 4 })
        // Las tareas de update pueden terminar en cualquier orden: se comprueba la última por entrada.
        let updates = manager.log.current.updates
        func last(_ id: InputID) -> InputDescriptor? { updates.last { $0.id == id } }
        #expect(last(h.image)?.fit == .fill)
        #expect(updates.contains { $0.id == h.video && $0.loop })
        #expect(updates.contains { $0.id == h.video && $0.inPoint == 2 && $0.outPoint == 9 })
        #expect(last(h.color)?.content == .color(RGBAColor(red: 0, green: 1, blue: 0)))
        #expect(manager.log.current.removes.isEmpty)
        #expect(manager.log.current.adds.count == adds)
    }

    // MARK: 5 · Otro lienzo / frecuencia

    @Test func openingAProjectWithAnotherCanvasReconfigures() async {
        let formats = Box<[CanvasFormat]>([])
        let store = MockProjectStore()
        let h = harness(TestInputManager()) { services in
            services.store = store
            services.reconfigureCanvas = { formats.value.append($0) }
        }
        let same = URL(fileURLWithPath: "/tmp/same.minimix")
        h.app.saveProject(to: same)
        await h.app.openProject(from: same)
        #expect(formats.value.isEmpty)
        let other = CanvasFormat(size: .hd720, frameRate: .fps25)
        let url = URL(fileURLWithPath: "/tmp/other.minimix")
        try? store.save(Project(canvas: other), to: url)
        await h.app.openProject(from: url)
        #expect(formats.value == [other])
    }

    // MARK: 6 · Ciclo de vida

    @Test func stopAndStartKeepTicksRuntimeAndInputs() async {
        let manager = TestInputManager()
        let runtimeEvents = Box<[String]>([])
        let h = harness(manager) { services in
            services.startRuntime = {
                runtimeEvents.value.append("start")
                return ["El audio no arrancó: prueba"]
            }
            services.stopRuntime = { runtimeEvents.value.append("stop") }
        }
        h.app.start()
        #expect(h.app.errorMessage == "El audio no arrancó: prueba")
        #expect(await eventually { manager.log.current.adds.count == 5 })
        h.app.stop()
        h.app.start()
        #expect(runtimeEvents.value == ["start", "stop", "start"])
        // Las entradas no se vuelven a dar de alta (Media lanzaría `duplicate`).
        try? await Task.sleep(for: .milliseconds(50))
        #expect(manager.log.current.adds.count == 5)
        // Los ticks se vuelven a recibir tras stop + start (suscripción nueva).
        h.app.send(.fade(duration: 0.1))
        #expect(h.app.transitionProgress != nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while h.app.transitionProgress != nil, ContinuousClock.now < deadline {
            h.clock.advance(frames: 3)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(h.app.transitionProgress == nil, "el fundido avanzó con los ticks tras reiniciar")
        h.app.stop()
    }

    // MARK: 7 · Salida y errores de servicio

    @Test func outputDisplayIsRememberedAndPreventsAppNap() async {
        let output = FakeOutput()
        let h = harness(TestInputManager()) { $0.output = output }
        h.app.toggleProgramOutput()
        #expect(output.activeDisplay == 7)
        #expect(output.preventsAppNap)
        let defaults = h.app.services.defaults
        #expect(defaults.string(forKey: AppViewModel.outputDisplayKey) == "UUID-7")

        // Nueva sesión con las mismas preferencias: restaura la pantalla.
        let output2 = FakeOutput()
        let h2 = harness(TestInputManager()) { services in
            services.output = output2
            services.defaults = defaults
        }
        h2.app.start()
        #expect(output2.restoredUUIDs == ["UUID-7"])
        #expect(output2.preventsAppNap)
        h2.app.toggleProgramOutput() // ocultar olvida la elección
        #expect(!output2.preventsAppNap)
        #expect(defaults.string(forKey: AppViewModel.outputDisplayKey) == nil)
        h2.app.stop()
    }

    @Test func serviceErrorsAreShown() async {
        let (errors, continuation) = AsyncStream.makeStream(of: String.self)
        let h = harness(TestInputManager()) { $0.serviceErrors = errors }
        h.app.start()
        continuation.yield("No se pudo conectar el audio de «Música»")
        #expect(await eventually { h.app.errorMessage?.contains("Música") == true })
        h.app.stop()
    }

    // MARK: 8 · Publicación del BusState

    @Test func busStateIsPublishedOnlyWhenItChanges() {
        let published = Box<[(BusState, Bool)]>([])
        let h = harness(TestInputManager()) { services in
            services.busStateSink = { published.value.append(($0, $1)) }
        }
        h.app.publishBusState()
        h.app.publishBusState()
        #expect(published.value.count == 1)
        h.app.publishBusState(sourcesChanged: true)
        #expect(published.value.count == 2)
        #expect(published.value.last?.1 == true)
        h.app.send(.selectPreview(h.color))
        #expect(published.value.count == 3)
        h.app.send(.selectPreview(h.color)) // sin cambios
        #expect(published.value.count == 3)
    }
}

/// Caja de referencia para que los cierres de servicios registren llamadas en los tests.
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
