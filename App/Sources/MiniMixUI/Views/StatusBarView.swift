import SwiftUI

/// Barra de estado (sección 2.1, Diagnóstico): fps reales y fotogramas perdidos del render, RAM
/// (phys_footprint), carga de GPU, estado térmico, decodificadores, lienzo y salida. Los avisos
/// (térmico ≥ alto, decodificadores al límite, 4K) se muestran destacados.
struct StatusBarView: View {
    let app: AppViewModel

    var body: some View {
        let status = app.status
        let warnings = StatusViewModel.warnings(thermal: status.thermal, decoders: status.decoders,
                                                experimentalCanvas: app.isExperimentalCanvas)
        HStack(spacing: 14) {
            metric(String(format: "%.2f fps", status.fps), label: "Fotogramas por segundo")
            metric("\(status.droppedFrames) perdidos", label: "Fotogramas perdidos",
                   warning: status.droppedFrames > 0)
            metric("RAM \(Formatting.memory(status.memoryBytes))", label: "Memoria")
            metric(String(format: "GPU %.0f %%", status.gpuPercent), label: "Carga de GPU",
                   warning: status.gpuPercent >= 85)
            Label("Térmico: \(status.thermal.label)",
                  systemImage: status.thermalIsWarning ? "thermometer.high" : "thermometer.medium")
                .foregroundStyle(status.thermal == .critical ? Theme.critical
                                 : status.thermalIsWarning ? Theme.warning : .primary)
                .accessibilityLabel("Estado térmico")
                .accessibilityValue(status.thermal.label)
            if let decoders = status.decoders {
                metric("Decodificadores \(decoders.active)/\(decoders.limit)", label: "Decodificadores de vídeo activos",
                       warning: status.decodersAtLimit)
            }
            metric(canvasLabel, label: "Lienzo", warning: app.isExperimentalCanvas)
            Spacer()
            if let warning = warnings.first {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
                    .help(warnings.joined(separator: "\n"))
                    .accessibilityLabel("Aviso")
                    .accessibilityValue(warnings.joined(separator: ". "))
            }
            if let display = app.programOutputDisplay,
               let name = app.outputDisplays.first(where: { $0.id == display })?.name {
                Label("Salida: \(name)", systemImage: "display")
                    .foregroundStyle(Theme.program)
                    .accessibilityLabel("Salida de Programa en \(name)")
            }
            Text(app.documentName + (app.hasUnsavedChanges ? " — editado" : ""))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Proyecto")
                .accessibilityValue(app.documentName + (app.hasUnsavedChanges ? ", con cambios sin guardar" : ""))
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Barra de estado")
    }

    private var canvasLabel: String {
        let canvas = app.project.canvas
        let suffix = app.isExperimentalCanvas ? " (experimental)" : ""
        return "\(canvas.size.width)×\(canvas.size.height) · \(Preferences.label(for: canvas.frameRate))\(suffix)"
    }

    private func metric(_ text: String, label: String, warning: Bool = false) -> some View {
        Text(text)
            .foregroundStyle(warning ? Theme.warning : .primary)
            .accessibilityLabel(label)
            .accessibilityValue(text)
    }
}
