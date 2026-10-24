import AppKit
import Core
import Testing
@testable import Output

@MainActor
final class FakeDisplayProvider: DisplayProviding {
    var displays: [DisplayDescriptor]
    private var onChange: (@MainActor @Sendable () -> Void)?
    private(set) var isObserving = false

    init(_ displays: [DisplayDescriptor]) { self.displays = displays }

    func currentDisplays() -> [DisplayDescriptor] { displays }
    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        isObserving = true
    }
    func stopObserving() {
        onChange = nil
        isObserving = false
    }

    /// Simula `didChangeScreenParametersNotification`.
    func simulate(_ displays: [DisplayDescriptor]) {
        self.displays = displays
        onChange?()
    }
}

@MainActor
final class FakeSurface: ProgramSurface {
    private(set) var presented: [DisplayDescriptor] = []
    private(set) var dismissCount = 0
    private(set) var isVisible = false
    var current: DisplayDescriptor? { isVisible ? presented.last : nil }

    func present(on display: DisplayDescriptor) {
        presented.append(display)
        isVisible = true
    }
    func dismiss() {
        dismissCount += 1
        isVisible = false
    }
}

enum Screens {
    static let builtIn = DisplayDescriptor(
        info: DisplayInfo(id: 1, name: "Integrada", size: PixelSize(width: 2408, height: 1506), isBuiltIn: true),
        uuid: "UUID-BUILTIN", frame: CGRect(x: 0, y: 0, width: 1204, height: 753))
    static let projector = DisplayDescriptor(
        info: DisplayInfo(id: 5, name: "Proyector", size: .hd1080, isBuiltIn: false),
        uuid: "UUID-PROJECTOR", frame: CGRect(x: 1204, y: 0, width: 1920, height: 1080))
    static let tv = DisplayDescriptor(
        info: DisplayInfo(id: 6, name: "TV", size: .uhd4K, isBuiltIn: false),
        uuid: "UUID-TV", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

    /// El mismo proyector reconectado: otro `CGDirectDisplayID`, mismo UUID.
    static var projectorReconnected: DisplayDescriptor {
        var copy = projector
        copy.info = DisplayInfo(id: 9, name: "Proyector", size: .hd1080, isBuiltIn: false)
        return copy
    }

    /// El proyector tras cambiar a 720p.
    static var projector720: DisplayDescriptor {
        var copy = projector
        copy.info.size = .hd720
        copy.frame = CGRect(x: 1204, y: 0, width: 1280, height: 720)
        return copy
    }
}

@MainActor
@Suite("OutputController con pantallas simuladas")
struct OutputControllerTests {
    struct Harness {
        let output: OutputController
        let provider: FakeDisplayProvider
        let surface: FakeSurface
    }

    private func make(_ displays: [DisplayDescriptor] = [Screens.builtIn]) -> Harness {
        let provider = FakeDisplayProvider(displays)
        let surface = FakeSurface()
        return Harness(output: OutputController(provider: provider, surface: surface), provider: provider, surface: surface)
    }

    @Test func enumeratesAndObservesOnInit() {
        let harness = make([Screens.builtIn, Screens.projector])
        let output = harness.output
        let provider = harness.provider
        let surface = harness.surface
        #expect(output.displays == [Screens.builtIn.info, Screens.projector.info])
        #expect(output.activeDisplay == nil)
        #expect(provider.isObserving)
        #expect(!surface.isVisible)
    }

    @Test func prefersExternalDisplay() {
        let harness = make()
        let output = harness.output
        let provider = harness.provider
        let surface = harness.surface
        #expect(output.preferredDisplay == nil)
        #expect(!output.showOnPreferredDisplay())
        #expect(!surface.isVisible)

        provider.simulate([Screens.builtIn, Screens.projector])
        #expect(output.preferredDisplay == Screens.projector.info.id)
        #expect(output.showOnPreferredDisplay())
        #expect(output.activeDisplay == Screens.projector.info.id)
        #expect(surface.current == Screens.projector)
    }

    @Test func connectDisconnectReconnectAndResolutionChange() async {
        let harness = make()
        let output = harness.output
        let provider = harness.provider
        let surface = harness.surface
        var changes = output.displayChanges.makeAsyncIterator()

        // Conectar.
        provider.simulate([Screens.builtIn, Screens.projector])
        #expect(await changes.next() == [Screens.builtIn.info, Screens.projector.info])
        output.show(on: Screens.projector.info.id)
        #expect(output.activeDisplay == Screens.projector.info.id)
        #expect(output.selectedDisplayUUID == Screens.projector.uuid)

        // Desconectar la activa: se oculta sin olvidar la elección.
        provider.simulate([Screens.builtIn])
        #expect(await changes.next() == [Screens.builtIn.info])
        #expect(output.activeDisplay == nil)
        #expect(output.isAwaitingDisplay)
        #expect(!surface.isVisible)
        #expect(surface.dismissCount == 1)

        // Otra pantalla externa distinta no «roba» la salida.
        provider.simulate([Screens.builtIn, Screens.tv])
        _ = await changes.next()
        #expect(output.activeDisplay == nil)
        #expect(!surface.isVisible)

        // Reconectar (con otro id): vuelve sola a la pantalla recordada.
        provider.simulate([Screens.builtIn, Screens.tv, Screens.projectorReconnected])
        _ = await changes.next()
        #expect(output.activeDisplay == Screens.projectorReconnected.info.id)
        #expect(!output.isAwaitingDisplay)
        #expect(surface.current == Screens.projectorReconnected)

        // Cambio de resolución: se recoloca en el nuevo marco.
        provider.simulate([Screens.builtIn, Screens.projector720])
        #expect(await changes.next() == [Screens.builtIn.info, Screens.projector720.info])
        #expect(output.activeDisplay == Screens.projector720.info.id)
        #expect(surface.current?.frame == Screens.projector720.frame)
        #expect(output.displays.last?.size == .hd720)
    }

    @Test func hideForgetsSelection() {
        let harness = make([Screens.builtIn, Screens.projector])
        let output = harness.output
        let provider = harness.provider
        let surface = harness.surface
        output.show(on: Screens.projector.info.id)
        output.hide()
        #expect(output.activeDisplay == nil)
        #expect(output.selectedDisplayUUID == nil)
        #expect(!output.isAwaitingDisplay)
        #expect(!surface.isVisible)

        provider.simulate([Screens.builtIn])
        provider.simulate([Screens.builtIn, Screens.projector])
        #expect(output.activeDisplay == nil)
        #expect(!surface.isVisible)
    }

    @Test func showOnUnknownDisplayIsIgnored() {
        let harness = make([Screens.builtIn])
        let output = harness.output
        let surface = harness.surface
        output.show(on: 42)
        #expect(output.activeDisplay == nil)
        #expect(output.selectedDisplayUUID == nil)
        #expect(surface.presented.isEmpty)
    }

    @Test func restoresSavedDisplayWhenItAppears() {
        let harness = make([Screens.builtIn])
        let output = harness.output
        let provider = harness.provider
        let surface = harness.surface
        output.show(displayUUID: Screens.projector.uuid)
        #expect(output.isAwaitingDisplay)
        #expect(!surface.isVisible)
        provider.simulate([Screens.builtIn, Screens.projector])
        #expect(output.activeDisplay == Screens.projector.info.id)
        #expect(surface.current == Screens.projector)
    }

    @Test func switchingDisplaysMovesTheOutput() {
        let harness = make([Screens.builtIn, Screens.projector, Screens.tv])
        let output = harness.output
        let surface = harness.surface
        output.show(on: Screens.projector.info.id)
        output.show(on: Screens.tv.info.id)
        #expect(output.activeDisplay == Screens.tv.info.id)
        #expect(surface.current == Screens.tv)
        #expect(output.selectedDisplayUUID == Screens.tv.uuid)
    }

    @Test func allDisplaysVanishWithoutCrash() {
        let harness = make([Screens.builtIn, Screens.projector])
        let output = harness.output
        let provider = harness.provider
        let surface = harness.surface
        output.show(on: Screens.projector.info.id)
        provider.simulate([])
        #expect(output.displays.isEmpty)
        #expect(output.activeDisplay == nil)
        #expect(output.preferredDisplay == nil)
        #expect(!surface.isVisible)
        provider.simulate([Screens.projector])
        #expect(output.activeDisplay == Screens.projector.info.id)
    }

    @Test func appNapPreventionToggles() {
        let harness = make()
        let output = harness.output
        #expect(!output.preventsAppNap)
        output.preventsAppNap = true
        output.preventsAppNap = true
        #expect(output.preventsAppNap)
        output.preventsAppNap = false
        #expect(!output.preventsAppNap)
    }

    @Test func controllerIsReleasedWhileObserving() {
        let provider = FakeDisplayProvider([Screens.builtIn, Screens.projector])
        weak var weakOutput: OutputController?
        do {
            let output = OutputController(provider: provider, surface: FakeSurface())
            weakOutput = output
        }
        #expect(weakOutput == nil)
        // El observador captura el controlador débilmente: avisar después no falla.
        provider.simulate([Screens.builtIn])
    }
}

@MainActor
@Suite("Pantallas reales")
struct ScreenDisplayProviderTests {
    /// Enumera las pantallas de esta máquina (en CI puede no haber ninguna) sin crear ventanas.
    @Test func enumeratesConnectedScreens() {
        let displays = ScreenDisplayProvider().currentDisplays()
        #expect(displays.count == NSScreen.screens.count)
        #expect(Set(displays.map(\.info.id)).count == displays.count)
        for display in displays {
            #expect(display.info.size.width > 0 && display.info.size.height > 0)
            #expect(!display.uuid.isEmpty)
            #expect(display.info.isBuiltIn == (CGDisplayIsBuiltin(display.info.id) != 0))
            #expect(ScreenDisplayProvider.screen(for: display.info.id) != nil)
        }
    }
}
