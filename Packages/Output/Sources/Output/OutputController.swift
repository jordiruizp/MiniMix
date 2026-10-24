// Output/OutputController.swift — salida de Programa en pantalla externa (T81).

import AppKit
import Core
import Foundation
import Render

/// Salida de Programa: enumera pantallas, muestra la ventana de Programa en la elegida y la mantiene
/// ante conexiones y desconexiones.
///
/// **Reconexión en caliente**: la pantalla elegida se recuerda por su UUID de CoreGraphics. Si
/// desaparece, la salida se oculta (`activeDisplay == nil`, `isAwaitingDisplay == true`) sin olvidar la
/// elección; cuando vuelve (aunque con otro `CGDirectDisplayID`), se muestra de nuevo sola. Un cambio de
/// resolución o de disposición recoloca la ventana. Solo `hide()` olvida la elección.
@MainActor
public final class OutputController: OutputPresenting {
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var activeDisplay: DisplayInfo.ID?
    /// Lista de pantallas tras cada cambio. **Un solo consumidor** (como todo `AsyncStream`): si varias
    /// partes de la App necesitan los cambios, que una los reparta. Guarda solo el último valor pendiente.
    public let displayChanges: AsyncStream<[DisplayInfo]>

    /// UUID de la pantalla elegida (persistible por la App para restaurarla con `show(displayUUID:)`).
    public private(set) var selectedDisplayUUID: String?

    private let provider: any DisplayProviding
    private let surface: any ProgramSurface
    private let continuation: AsyncStream<[DisplayInfo]>.Continuation
    private var descriptors: [DisplayDescriptor] = []
    private let appNap = AppNapActivity()

    /// Controlador con pantallas y superficie inyectadas (tests, o una fuente de pantallas propia).
    public init(provider: any DisplayProviding, surface: any ProgramSurface) {
        self.provider = provider
        self.surface = surface
        (displayChanges, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        descriptors = provider.currentDisplays()
        displays = descriptors.map(\.info)
        provider.startObserving { [weak self] in self?.refreshDisplays() }
    }

    /// Controlador real: `NSScreen` + ventana borderless con un `MonitorView` alimentado por `feed`.
    public convenience init(feed: MonitorFeed, renderer: MonitorRenderer?) {
        self.init(provider: ScreenDisplayProvider(), surface: ProgramWindowSurface(feed: feed, renderer: renderer))
    }

    /// Controlador real con el renderer compartido del contexto Metal (`nil` → salida negra).
    public convenience init(feed: MonitorFeed, context: MetalContext? = .shared) {
        self.init(feed: feed, renderer: context.flatMap(MonitorRenderer.shared(for:)))
    }

    /// Al destruirse, termina `displayChanges` y oculta la ventana de Programa (en el hilo principal).
    deinit {
        continuation.finish()
        let surface = surface
        if Thread.isMainThread {
            MainActor.assumeIsolated { surface.dismiss() }
        } else {
            Task { @MainActor in surface.dismiss() }
        }
    }

    // MARK: OutputPresenting

    public func show(on display: DisplayInfo.ID) {
        guard let descriptor = descriptors.first(where: { $0.info.id == display }) else {
            outputLog.error("OutputController: display \(display) is not connected")
            return
        }
        selectedDisplayUUID = descriptor.uuid
        present(descriptor)
    }

    public func hide() {
        selectedDisplayUUID = nil
        activeDisplay = nil
        surface.dismiss()
    }

    // MARK: Extras

    /// Pantalla por defecto para la salida: la primera externa; si no hay, nil
    /// (mostrar el Programa a pantalla completa sobre la integrada taparía la interfaz).
    public var preferredDisplay: DisplayInfo.ID? {
        displays.first { !$0.isBuiltIn }?.id
    }

    /// Muestra en `preferredDisplay`. Devuelve false si no hay pantalla externa.
    @discardableResult
    public func showOnPreferredDisplay() -> Bool {
        guard let id = preferredDisplay else { return false }
        show(on: id)
        return true
    }

    /// Restaura una elección guardada: la recuerda y, si la pantalla está conectada, muestra la salida
    /// (si no, lo hará al conectarse).
    public func show(displayUUID uuid: String) {
        selectedDisplayUUID = uuid
        reconcile()
    }

    /// Hay una pantalla elegida pero no está conectada: la salida espera a que vuelva.
    public var isAwaitingDisplay: Bool { selectedDisplayUUID != nil && activeDisplay == nil }

    /// Desactiva App Nap (y el reposo por inactividad de pantalla y sistema) mientras sea `true`.
    /// La App decide cuándo (p. ej. mientras la salida está activa).
    public var preventsAppNap: Bool {
        get { appNap.isActive }
        set { appNap.setActive(newValue, reason: "MiniMix: salida de Programa en directo") }
    }

    /// Relee las pantallas y reconcilia la salida. Lo llama la fuente de pantallas en cada cambio;
    /// público para forzarlo (p. ej. al volver de reposo).
    public func refreshDisplays() {
        descriptors = provider.currentDisplays()
        displays = descriptors.map(\.info)
        reconcile()
        continuation.yield(displays)
    }

    // MARK: Internos

    private func reconcile() {
        guard let uuid = selectedDisplayUUID else { return }
        if let descriptor = descriptors.first(where: { $0.uuid == uuid }) {
            present(descriptor)
        } else if activeDisplay != nil {
            activeDisplay = nil
            surface.dismiss()
        }
    }

    private func present(_ descriptor: DisplayDescriptor) {
        surface.present(on: descriptor)
        activeDisplay = descriptor.info.id
    }
}

/// Actividad de `ProcessInfo` que impide App Nap. `@unchecked Sendable`: solo se usa desde el hilo
/// principal; `endActivity` es seguro desde cualquier hilo, por eso `deinit` puede cerrarla.
final class AppNapActivity: @unchecked Sendable {
    static let options: ProcessInfo.ActivityOptions = [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical]
    private var token: (any NSObjectProtocol)?

    var isActive: Bool { token != nil }

    func setActive(_ active: Bool, reason: String) {
        if active, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: Self.options, reason: reason)
        } else if !active, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
