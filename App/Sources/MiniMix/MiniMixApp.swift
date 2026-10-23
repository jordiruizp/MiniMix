import AppKit
import MiniMixUI
import SwiftUI

@main
struct MiniMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Fase de mocks: `AppServices.mocks()`. En T80 → servicios reales.
    @State private var app = AppViewModel(services: .mocks())

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
