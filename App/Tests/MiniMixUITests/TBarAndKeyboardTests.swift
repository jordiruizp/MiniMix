import Core
import Testing
@testable import MiniMixUI

@Suite("T-bar con SwitcherState real")
@MainActor
struct TBarTests {
    @Test func dragToTopCompletesAndReleaseRearms() {
        let harness = Harness()
        let (preview, program) = (harness.project.preview, harness.project.program)
        harness.app.moveTBar(to: 0.5)
        #expect(harness.app.transitionProgress == 0.5)
        harness.app.moveTBar(to: 1)
        #expect(harness.project.program == preview)
        #expect(harness.project.preview == program)
        // La palanca sigue arriba mientras se arrastra: no dispara otra transición.
        harness.app.moveTBar(to: 1)
        harness.app.moveTBar(to: 0.8)
        #expect(harness.project.program == preview)
        #expect(harness.app.transitionProgress == nil)
        harness.app.releaseTBar()
        #expect(harness.app.tbarPosition == 0)
        // Tras soltar, la T-bar vuelve a funcionar (no queda «muerta»).
        harness.app.moveTBar(to: 0.4)
        #expect(harness.app.transitionProgress == 0.4)
        harness.app.moveTBar(to: 1)
        harness.app.releaseTBar()
        #expect(harness.project.program == program)
    }

    @Test func cutCompletingManualTransitionRearmsLever() {
        let harness = Harness()
        harness.app.moveTBar(to: 0.6)
        harness.app.releaseTBar() // transición manual a medias: la palanca se queda
        #expect(harness.app.tbarPosition == 0.6)
        harness.app.send(.cut)
        #expect(harness.app.tbarPosition == 0)
        harness.app.moveTBar(to: 0.2)
        #expect(harness.app.transitionProgress == 0.2)
    }

    @Test func releaseWithoutTransitionReturnsToZero() {
        let harness = Harness()
        harness.app.selectInput(harness.video) // Preview == Programa: la T-bar no hace nada
        harness.app.moveTBar(to: 0.7)
        #expect(harness.app.transitionProgress == nil)
        harness.app.releaseTBar()
        #expect(harness.app.tbarPosition == 0)
    }

    @Test func leverGrabbedDuringAutoFadeIsIgnoredUntilRelease() {
        let harness = Harness()
        let (preview, program) = (harness.project.preview, harness.project.program)
        harness.app.send(.fade(duration: 1))
        harness.app.moveTBar(to: 0.3) // agarrada durante el fundido: SwitcherState la ignora
        harness.app.tick(at: HostTime(seconds: 1))
        #expect(harness.project.program == preview)
        harness.app.moveTBar(to: 0.6) // sin el bloqueo, arrancaría otra transición
        #expect(harness.app.transitionProgress == nil)
        #expect(harness.project.program == preview)
        harness.app.releaseTBar()
        #expect(harness.app.tbarPosition == 0)
        harness.app.moveTBar(to: 0.5)
        #expect(harness.app.transitionProgress == 0.5)
        harness.app.moveTBar(to: 1)
        #expect(harness.project.program == program)
    }

    @Test func relativeDragMath() {
        #expect(TBar.position(start: 0.25, delta: 50, length: 100) == 0.75)
        #expect(TBar.position(start: 0.9, delta: 50, length: 100) == 1)
        #expect(TBar.position(start: 0.1, delta: -50, length: 100) == 0)
        #expect(TBar.position(start: 0.3, delta: 10, length: 0) == 0.3)
        #expect(VerticalFader.value(start: 1, deltaY: -25, height: 100) == 1.5)
        #expect(VerticalFader.value(start: 1, deltaY: 100, height: 100) == 0)
    }
}

@Suite("Atajos: contexto de ventana")
struct ShortcutContextTests {
    private func context(main: Bool = true, key: Bool = true, sheet: Bool = false,
                         repeating: Bool = false, editing: Bool = false) -> ShortcutContext {
        ShortcutContext(isMainWindow: main, isKeyWindow: key, hasSheetOrModal: sheet,
                        isRepeat: repeating, isEditingText: editing)
    }

    @Test func onlyInKeyMainWindowWithoutSheetsRepeatsOrEditing() {
        #expect(context().allowsShortcuts)
        #expect(!context(main: false).allowsShortcuts)    // popover u otra ventana
        #expect(!context(key: false).allowsShortcuts)
        #expect(!context(sheet: true).allowsShortcuts)    // alerta, panel de guardar
        #expect(!context(repeating: true).allowsShortcuts)
        #expect(!context(editing: true).allowsShortcuts)
    }
}
