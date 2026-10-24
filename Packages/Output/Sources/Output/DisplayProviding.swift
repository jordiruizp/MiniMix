// Output/DisplayProviding.swift — fuente de pantallas (real con NSScreen/CoreGraphics, falsa en tests).

import AppKit
import Core
import CoreGraphics

/// Pantalla conectada, con lo que necesita `OutputController` además de `DisplayInfo`.
public struct DisplayDescriptor: Hashable, Sendable {
    public var info: DisplayInfo
    /// UUID estable de la pantalla (`CGDisplayCreateUUIDFromDisplayID`): sobrevive a desconexiones,
    /// mientras que el `CGDirectDisplayID` puede cambiar al reconectar.
    public var uuid: String
    /// Marco en puntos, en coordenadas globales de `NSScreen` (donde se coloca la ventana).
    public var frame: CGRect

    public init(info: DisplayInfo, uuid: String, frame: CGRect) {
        self.info = info
        self.uuid = uuid
        self.frame = frame
    }
}

/// Fuente de pantallas para `OutputController`. La real es `ScreenDisplayProvider`; los tests usan una
/// falsa para simular conexiones, desconexiones y cambios de resolución sin hardware.
@MainActor
public protocol DisplayProviding: AnyObject {
    /// Pantallas conectadas ahora.
    func currentDisplays() -> [DisplayDescriptor]
    /// Empieza a avisar (en el hilo principal) cada vez que cambia la configuración de pantallas.
    /// Una llamada nueva sustituye al observador anterior.
    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void)
    func stopObserving()
}

/// Pantallas reales: `NSScreen.screens` + CoreGraphics; cambios por
/// `NSApplication.didChangeScreenParametersNotification` (conexión, desconexión, resolución, disposición).
@MainActor
public final class ScreenDisplayProvider: DisplayProviding {
    private let observation = NotificationObservation()

    public init() {}

    public func currentDisplays() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap(Self.descriptor(for:))
    }

    public func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        observation.token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    public func stopObserving() {
        observation.token = nil
    }

    /// `CGDirectDisplayID` de una `NSScreen`.
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// `NSScreen` con ese `CGDirectDisplayID`, si está conectada.
    public static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    static func descriptor(for screen: NSScreen) -> DisplayDescriptor? {
        guard let id = displayID(of: screen) else { return nil }
        let info = DisplayInfo(id: id, name: screen.localizedName, size: pixelSize(of: id, screen: screen),
                               isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        return DisplayDescriptor(info: info, uuid: uuidString(for: id), frame: screen.frame)
    }

    /// Tamaño en píxeles del modo actual (en Retina, los píxeles reales, no los puntos).
    static func pixelSize(of id: CGDirectDisplayID, screen: NSScreen) -> PixelSize {
        if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return PixelSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let scale = screen.backingScaleFactor
        return PixelSize(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale))
    }

    /// UUID estable de la pantalla; si CoreGraphics no lo da, se usa el id (menos estable).
    static func uuidString(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return "display-\(id)" }
        return string as String
    }
}

/// Token de `NotificationCenter` que se da de baja al sustituirlo o al destruirse.
/// `@unchecked Sendable`: solo se modifica desde el hilo principal (lo usa una clase `@MainActor`);
/// `removeObserver` es seguro desde cualquier hilo, por eso `deinit` puede llamarlo.
final class NotificationObservation: @unchecked Sendable {
    var token: (any NSObjectProtocol)? {
        didSet { if let oldValue { NotificationCenter.default.removeObserver(oldValue) } }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
