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
            let app = AppViewModel(services: .mocks())
            _app = State(initialValue: app)
            runtime = nil
            AppDelegate.install(app)
            return
        }
        do {
            // Proyecto inicial con los valores por defecto de las preferencias (lienzo, fps, fundido).
            let initial = Preferences.load(from: .standard).newProject
            let (services, runtime) = try AppServices.live(project: initial)
            let app = AppViewModel(services: services)
            _app = State(initialValue: app)
            self.runtime = runtime
            // El motor (audio + render) lo arranca `app.start()` desde la vista (no en init) y lo
            // para `app.stop()`; al salir, `applicationWillTerminate`.
            AppDelegate.install(app)
            FileHandle.standardOutput.write(Data("live: ok\n".utf8)) // sin búfer; lo busca scripts/smoke-app.sh
        } catch {
            // Un fallo real nunca pasa en silencio a la demo: se avisa y, si se exige el modo real, se sale.
            FileHandle.standardError.write(Data("live: failed: \(error)\n".utf8))
            if env["MINIMIX_REQUIRE_LIVE"] != nil { exit(1) }
            let demo = AppViewModel(services: .mocks())
            demo.errorMessage = "No se pudieron iniciar los servicios reales (\(error)). Modo demostración."
            _app = State(initialValue: demo)
            runtime = nil
            AppDelegate.install(demo)
        }
    }

    var body: some Scene {
        Window("MiniMix", id: "main") {
            RootView(app: app)
        }
        .commands { MiniMixCommands(app: app) }
        Settings {
            PreferencesView(app: app)
        }
    }
}

/// Necesario al ejecutar el binario fuera de un .app: activa la app y trae la ventana al frente.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Parada ordenada (reloj, render y audio) al salir.
    @MainActor static var onTerminate: (() -> Void)?
    /// Confirmación de salida con cambios sin guardar (true = salir).
    @MainActor static var shouldTerminate: (() -> Bool)?

    @MainActor static func install(_ app: AppViewModel) {
        onTerminate = { app.stop() }
        shouldTerminate = { ProjectDialogs.confirmDiscard(app) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (Self.shouldTerminate?() ?? true) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.onTerminate?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
