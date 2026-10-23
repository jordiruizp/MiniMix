import Core
import CoreMocks
import Foundation
import Testing
@testable import MiniMixUI

@Suite("AppViewModel: buses, selección, entradas, proyecto")
@MainActor
struct AppViewModelTests {
    @Test func selectingAnInputSetsSelectionAndPreview() {
        let harness = Harness()
        harness.app.selectInput(harness.music)
        #expect(harness.app.selectedInputID == harness.music)
        #expect(harness.project.preview == harness.music)
        #expect(harness.inputs.visible.current == [harness.music, harness.video])
    }

    @Test func cutSwapsBusesAndNotifiesAudio() {
        let harness = Harness()
        let (preview, program) = (harness.project.preview, harness.project.program)
        harness.app.send(.cut)
        #expect(harness.project.preview == program)
        #expect(harness.project.program == preview)
        let call = harness.audio.recorded.current.lastTransition
        #expect(call?.from == program && call?.to == preview && call?.progress == 1)
    }

    @Test func fadeDurationIsClamped() {
        let harness = Harness()
        harness.app.fadeDuration = 0.01
        #expect(harness.app.fadeDuration == 0.1)
        harness.app.fadeDuration = 9
        #expect(harness.app.fadeDuration == 5)
        #expect(harness.project.defaultFadeDuration == 5)
    }

    @Test func remainingTimeAndSimulatedEnd() {
        let harness = Harness()
        harness.app.send(.play(harness.video)) // /tmp/clip.mov dura 95 s en los mocks
        harness.advance(to: 10)
        #expect(harness.app.remaining(for: harness.video) == 85)
        harness.app.send(.pause(harness.video))
        harness.advance(to: 50)
        #expect(harness.app.remaining(for: harness.video) == 85)
        harness.app.send(.play(harness.video))
        harness.advance(to: 200)
        #expect(harness.app.playback[harness.video]?.state == .ended)
        #expect(harness.app.remaining(for: harness.image) == nil)
    }

    @Test func trimsShortenDuration() {
        let harness = Harness()
        harness.app.updateInput(harness.video) {
            $0.inPoint = 5
            $0.outPoint = 25
        }
        #expect(harness.app.remaining(for: harness.video) == 20)
    }

    @Test func dropFilesCreatesInputsByExtension() throws {
        let harness = Harness()
        let urls = ["clip.MOV", "logo.png", "song.wav", "notes.txt"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(harness.app.addInputs(from: urls) == 3)
        let added = harness.project.inputs.suffix(3)
        #expect(added.map(\.kind) == [.video, .image, .audio])
        #expect(added.map(\.name) == ["clip", "logo", "song"])
        #expect(try #require(added.first).content.mediaReference?.path == "/tmp/clip.MOV")
    }

    @Test func contextMenuEdits() {
        let harness = Harness()
        harness.app.rename(harness.video, to: "  Cámara  ")
        #expect(harness.input(1).name == "Cámara")
        harness.app.rename(harness.video, to: "   ")
        #expect(harness.input(1).name == "Cámara")
        harness.app.setFit(.fill, for: harness.video)
        #expect(harness.input(1).fit == .fill)
        harness.app.send(.setLoop(harness.video, true))
        #expect(harness.input(1).loop)
        harness.app.send(.setAudioFollowsProgram(harness.video, false))
        #expect(!harness.input(1).audioFollowsProgram)
        #expect(harness.audio.recorded.current.follows[harness.video] == false)
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        harness.app.setColor(red, for: harness.color)
        #expect(harness.input(3).content == .color(red))
    }

    @Test func removeInputClearsBusesThroughSwitcher() {
        let harness = Harness()
        let count = harness.project.inputs.count
        harness.app.removeInput(harness.image) // en Preview
        #expect(harness.project.inputs.count == count - 1)
        #expect(harness.project.preview == nil)
        harness.app.send(.cut) // sin Preview: no hace nada (no queda un bus colgando)
        #expect(harness.project.program == harness.video)
        harness.app.removeInput(harness.video) // en Programa
        #expect(harness.project.program == nil)
        #expect(harness.project.inputs.count == count - 2)
    }

    @Test func removeInputRefusedDuringTransition() {
        let harness = Harness()
        harness.app.send(.fade(duration: 1))
        #expect(harness.app.transitionProgress != nil)
        harness.app.removeInput(harness.image)
        harness.app.removeInput(harness.video)
        #expect(harness.project.inputs.count == 5)
        #expect(harness.app.errorMessage != nil)
        harness.app.removeInput(harness.color) // no participa
        #expect(harness.project.inputs.count == 4)
    }

    @Test func fadeRunsOnClockTicks() {
        let harness = Harness()
        harness.app.send(.fade(duration: 1))
        harness.app.tick(at: HostTime(seconds: 0.5))
        #expect(harness.app.transitionProgress == 0.5)
        #expect(harness.audio.recorded.current.lastTransition?.progress == 0.5)
        harness.app.tick(at: HostTime(seconds: 1))
        #expect(harness.app.transitionProgress == nil)
        #expect(harness.project.program == harness.image)
    }

    @Test func openProjectResetsTransition() async {
        let harness = Harness()
        let url = URL(fileURLWithPath: "/tmp/reset.minimix")
        harness.app.saveProject(to: url)
        harness.app.moveTBar(to: 0.4)
        #expect(harness.app.transitionProgress != nil)
        await harness.app.openProject(from: url)
        #expect(harness.app.transition == .idle)
        #expect(harness.app.tbarPosition == 0)
        harness.app.releaseTBar()
        harness.app.moveTBar(to: 0.3) // la T-bar sigue viva con el switcher nuevo
        #expect(harness.app.transitionProgress == 0.3)
    }

    @Test func seekCountsFromInPoint() {
        let harness = Harness()
        harness.app.updateInput(harness.video) { $0.inPoint = 10 }
        harness.app.send(.seek(harness.video, seconds: 30))
        #expect(harness.app.remaining(for: harness.video) == 65)
    }

    @Test func addColorAndPlaylistInputs() {
        let harness = Harness()
        harness.app.addColorInput()
        harness.app.addPlaylistInput()
        #expect(harness.project.inputs.suffix(2).map(\.kind) == [.color, .playlist])
        #expect(harness.app.selectedInput?.kind == .playlist)
    }

    @Test func saveAndOpenRoundTrip() async {
        let harness = Harness()
        let url = URL(fileURLWithPath: "/tmp/test.minimix")
        harness.app.rename(harness.video, to: "Guardado")
        harness.app.saveProject(to: url)
        #expect(harness.app.projectURL == url)
        harness.app.rename(harness.video, to: "Cambiado")
        await harness.app.openProject(from: url)
        #expect(harness.input(1).name == "Guardado")
        await harness.app.openProject(from: URL(fileURLWithPath: "/tmp/no-existe.minimix"))
        #expect(harness.app.errorMessage != nil)
    }

    @Test func toggleProgramOutputPrefersExternalDisplay() {
        let harness = Harness()
        harness.app.toggleProgramOutput()
        #expect(harness.output.activeDisplay == 2)
        #expect(harness.app.programOutputDisplay == 2)
        harness.app.toggleProgramOutput()
        #expect(harness.output.activeDisplay == nil)
    }

    @Test func statusBarUsesRenderStats() {
        let harness = Harness()
        harness.app.status.refresh()
        #expect(harness.app.status.fps == 60)
        #expect(abs(harness.app.status.gpuPercent - 33.6) < 0.01)
        #expect((harness.app.status.memoryBytes ?? 0) > 0)
    }
}

@Suite("Utilidades")
struct UtilityTests {
    @Test func hexColors() throws {
        let color = try #require(RGBAColor(hex: "#FF8000"))
        #expect(color.red == 1 && color.blue == 0 && abs(color.green - 128.0 / 255) < 1e-9)
        #expect(color.hexString == "#FF8000")
        #expect(RGBAColor(hex: "0f0") == nil) // Core no acepta #RGB
        #expect(RGBAColor(hex: "00ff00")?.hexString == "#00FF00")
        #expect(RGBAColor(hex: "#00000080")?.hexString == "#00000080")
        #expect(RGBAColor(hex: "zzz") == nil)
        #expect(RGBAColor(hex: "#12345") == nil)
    }

    @Test func formatting() {
        #expect(Formatting.clock(65) == "1:05")
        #expect(Formatting.clock(3_661) == "1:01:01")
        #expect(Formatting.remaining(nil) == "--:--")
        #expect(Formatting.remaining(9.2) == "-0:10")
        #expect(Formatting.decibels(gain: 1) == "+0.0 dB")
        #expect(Formatting.decibels(gain: 0) == "−∞ dB")
    }
}
