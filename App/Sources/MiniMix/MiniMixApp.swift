import AppKit
import MiniMixUI
import SwiftUI

@main
struct MiniMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppViewModel
    private let runtime: LiveRuntime?

    init() {
        // T80: servicios reales. MINIMIX_MOCKS=1 (o sin GPU/audio) → demo con mocks.
        if ProcessInfo.processInfo.environment["MINIMIX_MOCKS"] == nil,
           let (services, runtime) = try? AppServices.live() {
            _app = State(initialValue: AppViewModel(services: services))
            self.runtime = runtime
            runtime.start()
        } else {
            _app = State(initialValue: AppViewModel(services: .mocks()))
            runtime = nil
        }
    }

    var body: some Scene {
        Window("MiniMix", id: "main") {
            RootView(app: app)
        }
        .commands { MiniMixCommands(app: app) }
    }
}

/// Necesario al ejecutar el binario fuera de un .app: activa la app y trae la ventana al frente.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
