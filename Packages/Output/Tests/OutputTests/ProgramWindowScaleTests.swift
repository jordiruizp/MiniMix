import AppKit
import Core
import Foundation
import MetalKit
import Testing
@testable import Output
import Render

/// Regresión del «Programa en negro» en un monitor externo de 1× (DELL S2421HN 1920×1080, Mac Retina):
/// la ventana se creaba en la pantalla principal (2×) y se movía a la de 1×; el `CAMetalLayer` del
/// `MTKView` (dentro de `NSHostingView`) quedaba con `contentsScale == 0` y la salida se veía negra
/// aunque `draw(in:)` presentara drawables. La ventana debe nacer con la escala de su pantalla y
/// recrearse si cambia a una pantalla de otra escala.
@MainActor
@Suite("Ventana de Programa y escala de pantalla")
struct ProgramWindowScaleTests {
    static func findMTKView(in view: NSView?) -> MTKView? {
        guard let view else { return nil }
        if let mtk = view as? MTKView { return mtk }
        for sub in view.subviews { if let found = findMTKView(in: sub) { return found } }
        return nil
    }

    /// Sin mostrar nada: la ventana se crea con la escala de la pantalla de destino (apto para CI).
    @Test func windowIsBornWithTargetScreenScale() {
        for display in ScreenDisplayProvider().currentDisplays() {
            let surface = ProgramWindowSurface(feed: MonitorFeed(), renderer: nil)
            let window = surface.prepareWindow(for: display)
            #expect(window.backingScaleFactor == ProgramWindowSurface.backingScale(of: display),
                    "\(display.info.name)")
        }
    }

    /// Sin mostrar nada: al pasar a una pantalla de otra escala la ventana se recrea.
    @Test func windowIsRecreatedWhenScaleChanges() {
        let displays = ScreenDisplayProvider().currentDisplays()
        guard let first = displays.first,
              let other = displays.first(where: {
                  ProgramWindowSurface.backingScale(of: $0) != ProgramWindowSurface.backingScale(of: first) })
        else { return } // hace falta un monitor con otra escala (p. ej. Retina + 1080p de 1×)
        let surface = ProgramWindowSurface(feed: MonitorFeed(), renderer: nil)
        let before = surface.prepareWindow(for: first)
        let after = surface.prepareWindow(for: other)
        #expect(before !== after)
        #expect(after.backingScaleFactor == ProgramWindowSurface.backingScale(of: other))
        #expect(surface.prepareWindow(for: other) === after)
    }

    /// Con `MINIMIX_MANUAL_OUTPUT=1` y un monitor externo: muestra la salida en él y comprueba que el
    /// `CAMetalLayer` del monitor tiene la escala de la pantalla (con el fallo era 0).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINIMIX_MANUAL_OUTPUT"] == "1"))
    func externalOutputLayerHasScreenScale() throws {
        guard let context = MetalContext.shared,
              let external = ScreenDisplayProvider().currentDisplays().first(where: { !$0.info.isBuiltIn }) else { return }
        let surface = ProgramWindowSurface(feed: MonitorFeed(), context: context)
        surface.present(on: external)
        defer { surface.dismiss() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let window = try #require(surface.window)
        let layer = try #require(Self.findMTKView(in: window.contentView)?.layer as? CAMetalLayer)
        #expect(window.frame == external.frame)
        #expect(layer.contentsScale == window.backingScaleFactor)
        #expect(layer.contentsScale > 0)
    }
}
