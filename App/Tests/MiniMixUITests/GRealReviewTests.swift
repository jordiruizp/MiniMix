import AVFAudio
import Core
import CoreMocks
import Foundation
import Media
@testable import MiniMixUI
import Persistence
import Testing

/// Revisión del PR #12 (G-real): salida, ediciones en vuelo, audio tras `update`, reenlace en directo.
@Suite("G-real · revisión")
@MainActor
struct GRealReviewTests {
    private func harness(_ manager: TestInputManager = TestInputManager(), project: Project = SampleData.project,
                         configure: (@MainActor (inout AppServices) -> Void)? = nil) -> Harness {
        Harness(project: project, configure: { services in
            services.inputs = manager
            services.simulatesPlayback = false
            configure?(&services)
        })
    }

    // MARK: 1 · App Nap solo con la salida presentada

    @Test func awaitingAbsentDisplayDoesNotPreventSleep() {
        let output = FakeOutput()
        let h = harness { $0.output = output }
        h.app.services.defaults.set("UUID-9", forKey: AppViewModel.outputDisplayKey) // no conectada
        h.app.start()
        #expect(output.restoredUUIDs == ["UUID-9"])
        #expect(output.isAwaitingDisplay)
        #expect(!output.preventsAppNap)
        h.app.stop()
    }

    // MARK: 2 · Nunca en la pantalla integrada

    @Test func toggleWithoutExternalDisplayDoesNotUseBuiltIn() {
        let output = FakeOutput()
        output.displays = [DisplayInfo(id: 1, name: "Integrada", size: .hd1080, isBuiltIn: true)]
        let h = harness { $0.output = output }
        h.app.toggleProgramOutput()
        #expect(output.activeDisplay == nil)
        #expect(h.app.errorMessage != nil)
        #expect(h.app.services.defaults.string(forKey: AppViewModel.outputDisplayKey) == nil)
    }

    @Test func rememberedBuiltInDisplayIsForgotten() {
        let output = FakeOutput()
        output.displays = [DisplayInfo(id: 1, name: "Integrada", size: .hd1080, isBuiltIn: true)]
        let h = harness { $0.output = output }
        h.app.services.defaults.set("UUID-1", forKey: AppViewModel.outputDisplayKey) // preferencia antigua
        h.app.start()
        #expect(output.activeDisplay == nil)
        #expect(!output.preventsAppNap)
        #expect(h.app.services.defaults.string(forKey: AppViewModel.outputDisplayKey) == nil)
        h.app.stop()
    }

    // MARK: 4 · La baja espera a las ediciones en vuelo

    @Test func removeWaitsForInFlightEdits() async throws {
        let manager = TestInputManager(updateDelay: .milliseconds(80))
        let h = harness(manager)
        await h.app.registerAllInputs()
        let color = h.color // capturado: tras la baja, `h.color` apuntaría a otra entrada
        h.app.setColor(RGBAColor(red: 1, green: 0, blue: 0), for: color)
        try await Task.sleep(for: .milliseconds(20)) // el `update` ya está en vuelo en Media
        h.app.removeInput(color)
        #expect(await eventually { manager.calls.current.contains("remove") })
        #expect(manager.calls.current == ["update", "remove"])
        #expect(h.app.sourceSubscriptions[color] == nil)
        #expect(await eventually { h.app.pendingTasks.isEmpty })
    }

    // MARK: 5 · Cancelaciones no son errores

    @Test func cancelledUpdatesAreSilent() async {
        for error: any Error in [CancellationError(), MediaError.cancelled("x")] {
            let h = harness(TestInputManager(updateError: error))
            await h.app.registerAllInputs()
            h.app.send(.setFit(h.image, .fill))
            #expect(await eventually { h.app.pendingTasks.isEmpty })
            #expect(h.app.errorMessage == nil, "\(error)")
        }
        let h = harness(TestInputManager(updateError: MediaError.unreadable("roto")))
        await h.app.registerAllInputs()
        h.app.send(.setFit(h.image, .fill))
        #expect(await eventually { h.app.errorMessage != nil })
    }

    // MARK: 7 · `update` no pisa los ajustes de audio

    final class AudioHost: AudioChannelHosting, @unchecked Sendable {
        let calls = Locked([String]())
        func attach(_ source: AudioSource) throws { calls.withLock { $0.append("attach") } }
        func detach(_ id: InputID) { calls.withLock { $0.append("detach") } }
        func setVolume(_ volume: Float, for input: InputID) { calls.withLock { $0.append("volume \(volume)") } }
        func setMute(_ muted: Bool, for input: InputID) { calls.withLock { $0.append("mute \(muted)") } }
        func setAudioFollowsProgram(_ follows: Bool, for input: InputID) {
            calls.withLock { $0.append("follows \(follows)") }
        }
    }

    final class AudioInputs: InputManaging, @unchecked Sendable {
        let source = MockAudioSource(node: AVAudioPlayerNode())
        func add(_ descriptor: InputDescriptor) async throws {}
        func remove(_ id: InputID) async {}
        func update(_ descriptor: InputDescriptor) async throws {}
        func frameSource(for id: InputID) -> FrameSource? { nil }
        func audioSource(for id: InputID) -> AudioSource? { source }
        func setVisible(_ ids: Set<InputID>) {}
    }

    @Test func liveInputsUpdateKeepsCurrentAudioSettings() async throws {
        let host = AudioHost()
        let inputs = LiveInputs(inputs: AudioInputs(), audio: host)
        let descriptor = InputDescriptor(name: "Música", content: .audio(MediaReference(path: "/tmp/m.wav"), visual: .black),
                                         volume: 0.5)
        try await inputs.add(descriptor)
        #expect(host.calls.current == ["attach", "volume 0.5", "mute false", "follows true"])
        host.calls.withLock { $0.removeAll() }
        try await inputs.update(descriptor) // descriptor capturado antes de un cambio de volumen en la UI
        #expect(host.calls.current == ["attach"])
    }

    // MARK: 8 · Reenlace sin cortar el directo

    @Test func relinkUpdatesOnlyRelinkedInputsAndSearchesSubfolders() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("relink-\(UUID().uuidString)")
        let sub = folder.appendingPathComponent("sub/deeper")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try Data([0]).write(to: folder.appendingPathComponent("a.mov"))
        try Data([0]).write(to: sub.appendingPathComponent("b.png"))
        let gone = "/nonexistent-\(UUID().uuidString)"
        let color = InputDescriptor(name: "Color", content: .color(.black))
        let a = InputDescriptor(name: "A", content: .video(MediaReference(path: "\(gone)/a.mov")))
        let b = InputDescriptor(name: "B", content: .image(MediaReference(path: "\(gone)/other/b.png")))
        let project = Project(inputs: [color, a, b], program: color.id)
        let store = ProjectStore(bookmarkMode: .plain)
        let manager = TestInputManager()
        let h = harness(manager, project: project) { services in
            services.store = store
            services.relinkProject = { reference, url, project, folder in
                let result = try store.relinkReporting(reference, to: url, in: project, searchingIn: folder)
                return RelinkOutcome(project: result.project, relinkedPaths: result.relinkedPaths,
                                     stillUnresolved: result.stillUnresolved)
            }
        }
        let file = folder.appendingPathComponent("p.minimix")
        h.app.saveProject(to: file)
        await h.app.openProject(from: file)
        #expect(h.app.missingReferences.count == 2)
        h.app.setMediaDuration(42, forPath: "\(gone)/a.mov")
        let removesBefore = manager.log.current.removes.count
        let program = h.project.program

        let relinked = await h.app.relinkMissing(in: folder)
        #expect(relinked == 2)
        #expect(h.app.missingReferences.isEmpty)
        let newA = try #require(h.app.descriptor(a.id)?.content.mediaReference?.path)
        let newB = try #require(h.app.descriptor(b.id)?.content.mediaReference?.path)
        #expect(newA.hasSuffix("a.mov") && newA.contains(folder.lastPathComponent))
        #expect(newB.hasSuffix("sub/deeper/b.png"))
        #expect(h.app.mediaDurations[newA] == 42, "la duración conocida sigue a la ruta nueva")
        #expect(await eventually { h.app.pendingTasks.isEmpty })
        #expect(manager.log.current.removes.count == removesBefore, "sin replaceProject: nada se da de baja")
        #expect(h.project.program == program)
    }
}
