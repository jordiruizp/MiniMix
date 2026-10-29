import Core
import Foundation
import Output

/// Extras de la salida de Programa que no están en `OutputPresenting` (los tiene `OutputController`).
@MainActor
public protocol ProgramOutputControlling: AnyObject {
    /// UUID de la pantalla elegida (persistible).
    var selectedDisplayUUID: String? { get }
    /// Restaura una elección guardada (se muestra al conectarse si ahora no está).
    func show(displayUUID uuid: String)
    var isAwaitingDisplay: Bool { get }
    var preventsAppNap: Bool { get set }
}

extension OutputController: ProgramOutputControlling {}

/// Salida de Programa (OutputPresenting): ⌘⇧F, pantalla recordada y App Nap.
extension AppViewModel {
    static let outputDisplayKey = "MiniMix.programOutputDisplayUUID"

    private var outputExtras: ProgramOutputControlling? { services.output as? ProgramOutputControlling }

    /// Muestra u oculta la salida de Programa. Solo se muestra en una pantalla **externa** (en la
    /// integrada taparía la interfaz); sin externa se avisa. La pantalla elegida se guarda en las
    /// preferencias (nunca una integrada); ocultar la olvida.
    public func toggleProgramOutput() {
        let output = services.output
        if output.activeDisplay != nil || outputExtras?.isAwaitingDisplay == true {
            output.hide()
            services.defaults.removeObject(forKey: Self.outputDisplayKey)
        } else if let display = output.displays.first(where: { !$0.isBuiltIn }) {
            output.show(on: display.id)
            if let uuid = outputExtras?.selectedDisplayUUID {
                services.defaults.set(uuid, forKey: Self.outputDisplayKey)
            }
        } else {
            errorMessage = "Conecta una pantalla externa para mostrar la salida de Programa."
        }
        outputDisplaysChanged()
    }

    public var outputDisplays: [DisplayInfo] { services.output.displays }

    /// Al arrancar: vuelve a mostrar la salida en la pantalla guardada (o la espera).
    func restoreProgramOutput() {
        guard let uuid = services.defaults.string(forKey: Self.outputDisplayKey),
              let extras = outputExtras else { return }
        extras.show(displayUUID: uuid)
        outputDisplaysChanged()
    }

    /// Refleja la pantalla activa y desactiva App Nap (y el reposo de pantalla) solo mientras la
    /// salida está realmente presentada: esperando a una pantalla ausente, el Mac puede dormir.
    func outputDisplaysChanged() {
        programOutputDisplay = services.output.activeDisplay
        guard let extras = outputExtras else { return }
        let presented = programOutputDisplay != nil
        if extras.preventsAppNap != presented { extras.preventsAppNap = presented }
        // Una elección recordada que resulta ser la integrada (preferencias antiguas) se olvida.
        if let active = programOutputDisplay,
           services.output.displays.first(where: { $0.id == active })?.isBuiltIn == true {
            services.output.hide()
            services.defaults.removeObject(forKey: Self.outputDisplayKey)
            programOutputDisplay = nil
            if extras.preventsAppNap { extras.preventsAppNap = false }
        }
    }
}
