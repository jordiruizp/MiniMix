import AppKit
import Core
import Testing
@testable import Output
import Render

/// Configuración de la ventana real sin mostrarla (sin `orderFront`): apta para CI.
@MainActor
@Suite("Configuración de la ventana de Programa")
struct ProgramWindowConfigTests {
    @Test func externalWindowIsConfiguredToHideCursorWithoutTakingFocus() {
        let surface = ProgramWindowSurface(feed: MonitorFeed(), renderer: nil)
        let window = surface.prepareWindow(for: Screens.projector)
        #expect(!surface.isVisible)
        #expect(window.level.rawValue == NSWindow.Level.mainMenu.rawValue + 1)
        #expect(window.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]))
        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(!window.ignoresMouseEvents)
        #expect(window.styleMask == [.borderless])
        #expect(window.contentView is CursorHidingView)
        #expect(!window.hidesOnDeactivate)
    }

    @Test func builtInWindowLetsMouseThroughAndWindowIsReused() {
        let surface = ProgramWindowSurface(feed: MonitorFeed(), renderer: nil)
        let external = surface.prepareWindow(for: Screens.projector)
        let builtIn = surface.prepareWindow(for: Screens.builtIn)
        #expect(external === builtIn)
        #expect(builtIn.ignoresMouseEvents)
        #expect(!surface.isVisible)
    }
}
