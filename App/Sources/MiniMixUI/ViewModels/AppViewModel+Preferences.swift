import Core
import Foundation

/// Aplicación de las preferencias (T91) a los servicios y al proyecto actual.
extension AppViewModel {
    /// Aplica las preferencias que tienen efecto en directo. Al arrancar se aplican todas.
    func applyPreferences(changedFrom old: Preferences?) {
        let prefs = preferences
        if old?.latencyCompensationMs != prefs.latencyCompensationMs {
            services.setLatencyCompensation?(prefs.latencyCompensationMs)
        }
        if old?.efficiencyMode != prefs.efficiencyMode { services.setEfficiencyMode?(prefs.efficiencyMode) }
        if old?.preventAppNapWhileLive != prefs.preventAppNapWhileLive { outputDisplaysChanged() }
    }

    /// Formato del lienzo del proyecto actual (menú Proyecto › Formato…). Reconfigura reloj y
    /// render. No toca las preferencias (que son los valores por defecto para proyectos nuevos).
    public func setCanvas(_ canvas: CanvasFormat) {
        guard canvas.size.isValid, canvas.frameRate.isValid, canvas != project.canvas else { return }
        services.reconfigureCanvas?(canvas)
        project.canvas = canvas
    }

    /// Cambia el formato del proyecto pidiendo confirmación si la salida de Programa está en el
    /// aire (el render se reconfigura). Devuelve si se aplicó.
    @discardableResult
    public func requestProjectFormat(_ canvas: CanvasFormat, confirmWhileLive: () -> Bool) -> Bool {
        guard canvas != project.canvas else { return false }
        if programOutputDisplay != nil, !confirmWhileLive() { return false }
        setCanvas(canvas)
        return project.canvas == canvas
    }

    /// El lienzo es 4K: experimental en el hardware objetivo.
    public var isExperimentalCanvas: Bool { project.canvas.size.width >= PixelSize.uhd4K.width }
}
