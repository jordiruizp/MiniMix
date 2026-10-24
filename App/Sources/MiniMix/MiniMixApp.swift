import AppKit
import MiniMixUI
import SwiftUI

@main
struct MiniMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppViewModel
    private let runtime: LiveRuntime?

    init() {
        let env = ProcessInfo.processInfo.environment
        // MINIMIX_MOCKS=1 → demo con mocks (deliberado).
        if env["MINIMIX_MOCKS"] != nil {
            _app = State(initialValue: AppViewModel(services: .mocks()))
            runtime = nil
            return
        }
        do {
            let (services, runtime) = try AppServices.live()
            _app = State(initialValue: AppViewModel(services: services))
            self.runtime = runtime
            runtime.start()
            FileHandle.standardOutput.write(Data("live: ok\n".utf8)) // sin búfer; lo busca scripts/smoke-app.sh
        } catch {
            // Un fallo real nunca pasa en silencio a la demo: se avisa y, si se exige el modo real, se sale.
            FileHandle.standardError.write(Data("live: failed: \(error)\n".utf8))
            if env["MINIMIX_REQUIRE_LIVE"] != nil { exit(1) }
            let demo = AppViewModel(services: .mocks())
            demo.errorMessage = "No se pudieron iniciar los servicios reales (\(error)). Modo demostración."
            _app = State(initialValue: demo)
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
