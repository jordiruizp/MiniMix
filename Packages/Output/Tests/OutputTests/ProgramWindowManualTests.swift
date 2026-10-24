import AppKit
import Core
import Foundation
import Testing
@testable import Output
import Render

/// Ventana real. Solo con `MINIMIX_MANUAL_OUTPUT=1` (abre una ventana negra pequeña un instante):
/// comprueba que se crea, se muestra sin hacerse key, se recoloca y se oculta. No corre en CI.
@MainActor
@Suite("Ventana de Programa real",
       .enabled(if: ProcessInfo.processInfo.environment["MINIMIX_MANUAL_OUTPUT"] == "1"))
struct ProgramWindowManualTests {
    @Test func presentsWithoutTakingFocus() throws {
        let screen = try #require(ScreenDisplayProvider().currentDisplays().first)
        var small = screen
        small.frame = CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 320, height: 180)
        let surface = ProgramWindowSurface(feed: MonitorFeed(), context: .shared)
        surface.present(on: small)
        #expect(surface.isVisible)
        let window = try #require(surface.window)
        #expect(!window.isKeyWindow && !window.canBecomeKey && !window.canBecomeMain)
        #expect(window.frame == small.frame)

        small.frame.size = CGSize(width: 480, height: 270)
        surface.present(on: small)
        #expect(window.frame == small.frame)
        surface.dismiss()
        #expect(!surface.isVisible)
    }
}
