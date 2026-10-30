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

    /// Formato del lienzo del proyecto actual (Settings). Reconfigura reloj y render.
    public func setCanvas(_ canvas: CanvasFormat) {
        guard canvas.size.isValid, canvas.frameRate.isValid, canvas != project.canvas else { return }
        services.reconfigureCanvas?(canvas)
        project.canvas = canvas
        if let preset = Preferences.CanvasPreset(size: canvas.size) { preferences.canvasPreset = preset }
        preferences.frameRate = canvas.frameRate
    }

    /// El lienzo es 4K: experimental en el hardware objetivo.
    public var isExperimentalCanvas: Bool { project.canvas.size.width >= PixelSize.uhd4K.width }
}
