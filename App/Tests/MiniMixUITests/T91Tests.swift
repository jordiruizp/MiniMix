import AppKit
import Core
import CoreMocks
import Foundation
import Observation
import Metal
@testable import MiniMixUI
import Render
import Testing

/// T91 · Pulido: documento, menú Switcher, tema, atajos con foco, barra de estado, preferencias.
@Suite("T91")
@MainActor
struct T91Tests {
    // MARK: 1 · Documento y menú

    @Test func unsavedChangesIgnoreBusesAndClearOnSave() {
        let h = Harness()
        #expect(!h.app.hasUnsavedChanges)
        h.app.send(.cut)
        h.app.selectInput(h.music)
        #expect(!h.app.hasUnsavedChanges, "cambiar Preview/Programa no ensucia el documento")
        h.app.rename(h.video, to: "Cámara 1")
        #expect(h.app.hasUnsavedChanges)
        #expect(h.app.saveProject(to: URL(fileURLWithPath: "/tmp/t91.minimix")))
        #expect(!h.app.hasUnsavedChanges)
        #expect(h.app.documentName == "t91")
    }

    @Test func openingIsCleanButEditsDuringRegistrationAreKept() async {
        let manager = TestInputManager(updateDelay: nil)
        let h = Harness(configure: { $0.inputs = manager })
        let url = URL(fileURLWithPath: "/tmp/t91-open.minimix")
        h.app.saveProject(to: url)
        h.app.rename(h.video, to: "cambio")
        #expect(h.app.isDirty)
        await h.app.openProject(from: url)
        #expect(!h.app.isDirty, "abrir no deja un falso «editado»")
        // Una edición mientras se dan de alta las entradas no se pierde como «guardada».
        let opening = Task { await h.app.openProject(from: url) }
        await Task.yield()
        h.app.rename(h.video, to: "durante")
        await opening.value
        #expect(h.app.isDirty == (h.input(1).name == "durante"))
    }

    @Test func statusRefreshDoesNotRepublishUnchangedValues() {
        let status = StatusViewModel(renderStats: { RenderStats(fps: 60, droppedFrames: 0, gpuTimeMs: 5) },
                                     thermalState: { .nominal })
        status.refresh()
        let changed = Box(false)
        withObservationTracking {
            _ = status.fps
            _ = status.droppedFrames
            _ = status.gpuPercent
            _ = status.thermal
            _ = status.decoders
        } onChange: { MainActor.assumeIsolated { changed.value = true } }
        status.refresh()
        #expect(!changed.value)
    }

    @Test func confirmDiscardAsksOnlyWhenDirty() {
        let h = Harness()
        var asked = 0
        #expect(h.app.confirmDiscardChanges(ask: { asked += 1; return .cancel }, save: { false }))
        #expect(asked == 0)
        h.app.send(.setMasterVolume(0.5))
        #expect(!h.app.confirmDiscardChanges(ask: { .cancel }, save: { true }))
        #expect(h.app.confirmDiscardChanges(ask: { .discard }, save: { false }))
        #expect(!h.app.confirmDiscardChanges(ask: { .save }, save: { false }), "guardar falló o se canceló")
        #expect(h.app.confirmDiscardChanges(ask: { .save }, save: { true }))
    }

    @Test func newProjectUsesPreferencesAndIsClean() async {
        let h = Harness()
        h.app.preferences.canvasPreset = .hd720
        h.app.preferences.frameRate = .fps50
        h.app.preferences.defaultFadeDuration = 2
        h.app.rename(h.video, to: "x")
        await h.app.newProject()
        #expect(h.project.inputs.isEmpty)
        #expect(h.project.canvas == CanvasFormat(size: .hd720, frameRate: .fps50))
        #expect(h.app.fadeDuration == 2)
        #expect(h.app.projectURL == nil)
        #expect(!h.app.hasUnsavedChanges)
        #expect(h.app.documentName == "Sin título")
    }

    @Test func switcherMenuListsEveryShortcutWithItsKey() {
        let h = Harness()
        let items = h.app.switcherMenuItems
        #expect(items.map(\.key) == ["1", "2", "3", "4", "5", "Espacio", "Intro", "P", "←", "→"])
        #expect(items.allSatisfy { $0.menuTitle.hasSuffix("(\($0.key))") })
        let arrows = items.filter { $0.key == "←" || $0.key == "→" }
        #expect(arrows.allSatisfy { !$0.isEnabled }, "Programa no es una playlist")
        h.app.selectInput(h.playlist)
        h.app.send(.cut)
        #expect(h.app.switcherMenuItems.filter { $0.key == "→" }.allSatisfy { $0.isEnabled })
    }

    @Test func cutAndFadeMenuItemsNeedSomethingToTake() {
        let h = Harness()
        func enabled(_ key: String) -> Bool { h.app.switcherMenuItems.first { $0.key == key }?.isEnabled ?? false }
        #expect(enabled("Espacio") && enabled("Intro"))
        h.app.selectInput(h.video) // Preview == Programa
        #expect(!enabled("Espacio") && !enabled("Intro"))
        h.app.removeInput(h.video) // Programa y Preview vacíos
        #expect(!enabled("Espacio") && !enabled("Intro"))
    }

    // MARK: 2 · Tema claro/oscuro

    @Test func previewAndProgramColorsAreLegibleInBothModes() {
        for dark in [false, true] {
            #expect(Theme.contrastWithWhite(Theme.preview, dark: dark) >= 4.5, "PVW dark=\(dark)")
            #expect(Theme.contrastWithWhite(Theme.program, dark: dark) >= 4.5, "PGM dark=\(dark)")
        }
        let light = Theme.components(Theme.warning, dark: false)
        let dark = Theme.components(Theme.warning, dark: true)
        #expect(light.red != dark.red || light.green != dark.green, "el color de aviso se adapta al modo")
    }

    // MARK: 3 · Navegación por teclado

    @Test func onlyKeyActivatedControlsKeepSpaceWithFullKeyboardAccess() {
        let activates = { (responder: NSResponder?, fka: Bool) in
            KeyboardShortcutMonitor.controlActivatesWithKey(responder, fullKeyboardAccess: fka)
        }
        #expect(activates(NSButton(), true))
        #expect(activates(NSPopUpButton(), true))
        #expect(activates(NSSegmentedControl(), true))
        #expect(!activates(NSButton(), false), "sin navegación por teclado completa, Espacio es Cut")
        #expect(!activates(NSTableView(), true), "la lista de la playlist no roba Espacio")
        #expect(!activates(NSSlider(), true))
        #expect(!activates(NSView(), true))
        #expect(!activates(nil, true))
    }

    @Test func focusedControlKeepsSpaceAndEnter() {
        let context = ShortcutContext(isMainWindow: true, isKeyWindow: true, hasSheetOrModal: false,
                                      isRepeat: false, isEditingText: false, focusedControlUsesKey: true)
        #expect(!context.allowsShortcuts)
    }

    // MARK: 4 · Barra de estado

    @Test func statusWarnings() {
        #expect(StatusViewModel.warnings(thermal: .nominal, decoders: DecoderUsage(active: 2, limit: 4),
                                         experimentalCanvas: false).isEmpty)
        #expect(StatusViewModel.warnings(thermal: .fair, decoders: nil, experimentalCanvas: false).isEmpty)
        let all = StatusViewModel.warnings(thermal: .serious, decoders: DecoderUsage(active: 4, limit: 4),
                                           experimentalCanvas: true)
        #expect(all.count == 3)
        #expect(all[0].contains("Temperatura alta"))
        #expect(all[1].contains("4/4"))
        #expect(all[2].contains("4K"))
        #expect(StatusViewModel.warnings(thermal: .critical, decoders: nil, experimentalCanvas: false)
            .first?.contains("crítica") == true)
    }

    @Test func statusReadsRenderStatsDecodersAndThermal() {
        let status = StatusViewModel(renderStats: { RenderStats(fps: 59.94, droppedFrames: 3, gpuTimeMs: 8.34) },
                                     decoderUsage: { DecoderUsage(active: 4, limit: 4) },
                                     thermalState: { .serious })
        status.refresh()
        #expect(status.fps == 59.94)
        #expect(status.droppedFrames == 3)
        #expect(abs(status.gpuPercent - 8.34 * 59.94 / 10) < 0.001)
        #expect(status.thermalIsWarning)
        #expect(status.decodersAtLimit)
        #expect((status.memoryBytes ?? 0) > 0)
    }

    @Test func experimentalCanvasFlag() {
        let h = Harness()
        #expect(!h.app.isExperimentalCanvas)
        h.app.setCanvas(CanvasFormat(size: .uhd4K, frameRate: .fps30))
        #expect(h.app.isExperimentalCanvas)
    }

    // MARK: 5 · Preferencias

    @Test func preferencesRoundTripThroughDefaults() {
        let suite = DefaultsSuite()
        var prefs = Preferences()
        prefs.canvasPreset = .uhd4K
        prefs.frameRate = .fps29_97
        prefs.defaultFadeDuration = 2.5
        prefs.latencyCompensationMs = 120
        prefs.efficiencyMode = true
        prefs.preventAppNapWhileLive = false
        prefs.save(to: suite.defaults)
        #expect(Preferences.load(from: suite.defaults) == prefs)
        suite.defaults.set(9_999.0, forKey: Preferences.Key.latency)
        #expect(Preferences.load(from: suite.defaults).latencyCompensationMs == 500)
        #expect(Preferences.load(from: DefaultsSuite().defaults) == Preferences())
    }

    @Test func preferencesAreAppliedToServices() {
        let latency = Box<[Double]>([])
        let efficiency = Box<[Bool]>([])
        let canvases = Box<[CanvasFormat]>([])
        let h = Harness(configure: { services in
            services.setLatencyCompensation = { latency.value.append($0) }
            services.setEfficiencyMode = { efficiency.value.append($0) }
            services.reconfigureCanvas = { canvases.value.append($0) }
        })
        h.app.start()
        #expect(latency.value == [0])
        #expect(efficiency.value == [false])
        h.app.preferences.latencyCompensationMs = 80
        h.app.preferences.efficiencyMode = true
        #expect(latency.value == [0, 80])
        #expect(efficiency.value == [false, true])
        #expect(Preferences.load(from: h.app.services.defaults).latencyCompensationMs == 80)
        let format = CanvasFormat(size: .hd720, frameRate: .fps25)
        h.app.setCanvas(format)
        #expect(canvases.value == [format])
        #expect(h.project.canvas == format)
        #expect(h.app.preferences.canvasPreset == .hd1080, "el formato del proyecto no cambia los valores por defecto")
        #expect(h.app.hasUnsavedChanges)
        h.app.stop()
    }

    @Test func settingsDefaultsDoNotTouchTheOpenProject() {
        let h = Harness()
        let canvas = h.project.canvas
        let fade = h.app.fadeDuration
        h.app.preferences.canvasPreset = .uhd4K
        h.app.preferences.frameRate = .fps25
        h.app.preferences.defaultFadeDuration = 3
        #expect(h.project.canvas == canvas)
        #expect(h.app.fadeDuration == fade)
        #expect(!h.app.hasUnsavedChanges)
        #expect(h.app.preferences.newProject.canvas == CanvasFormat(size: .uhd4K, frameRate: .fps25))
        #expect(h.app.preferences.newProject.defaultFadeDuration == 3)
    }

    @Test func projectFormatAsksWhileOutputIsLive() {
        let output = FakeOutput()
        let h = Harness(configure: { $0.output = output })
        let format = CanvasFormat(size: .hd720, frameRate: .fps30)
        var asked = 0
        #expect(h.app.requestProjectFormat(format) { asked += 1; return false })
        #expect(asked == 0, "sin salida activa no pregunta")
        h.app.toggleProgramOutput()
        let other = CanvasFormat(size: .hd1080, frameRate: .fps50)
        #expect(!h.app.requestProjectFormat(other) { asked += 1; return false })
        #expect(asked == 1)
        #expect(h.project.canvas == format)
        #expect(h.app.requestProjectFormat(other) { true })
        #expect(h.project.canvas == other)
    }

    @Test func appNapPreferenceIsRespected() {
        let output = FakeOutput()
        let h = Harness(configure: { $0.output = output })
        h.app.preferences.preventAppNapWhileLive = false
        h.app.toggleProgramOutput()
        #expect(output.activeDisplay == 7)
        #expect(!output.preventsAppNap)
        h.app.preferences.preventAppNapWhileLive = true
        #expect(output.preventsAppNap)
    }

    // MARK: 6 · Mensajes claros

    @Test func unsupportedDroppedFilesAreExplained() {
        let h = Harness()
        let count = h.project.inputs.count
        #expect(h.app.addInputs(from: [URL(fileURLWithPath: "/tmp/notas.txt"), URL(fileURLWithPath: "/tmp/x.mov")]) == 1)
        #expect(h.project.inputs.count == count + 1)
        #expect(h.app.errorMessage?.contains("notas.txt") == true)
    }
}

/// Modo eficiencia del render: Preview a media frecuencia, Programa completo.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct EfficiencyModeTests {
    @Test func previewIsComposedEveryOtherFrame() throws {
        let context = try #require(MetalContext.shared)
        let renderer = try LiveRenderer(context: context, canvas: PixelSize(width: 16, height: 9),
                                        frameRate: .fps60) { _ in nil }
        renderer.efficiencyMode = true
        for frame in 0..<6 {
            renderer.render(at: HostTime(seconds: Double(frame) / 60))?.waitUntilCompleted()
        }
        #expect(renderer.renderedFrames == 6)
        #expect(renderer.renderedPreviewFrames == 3)
        renderer.efficiencyMode = false
        for frame in 6..<8 {
            renderer.render(at: HostTime(seconds: Double(frame) / 60))?.waitUntilCompleted()
        }
        #expect(renderer.renderedPreviewFrames == 5)
    }
}
