import SwiftUI

/// Barra de estado: fps · drops · RAM · GPU · térmico · salida.
struct StatusBarView: View {
    let app: AppViewModel

    var body: some View {
        let status = app.status
        HStack(spacing: 14) {
            Text(String(format: "%.2f fps", status.fps))
            Text("\(status.droppedFrames) drops").foregroundStyle(status.droppedFrames > 0 ? .orange : .primary)
            Text("RAM \(Formatting.memory(status.memoryBytes))")
            Text(String(format: "GPU %.0f %%", status.gpuPercent))
            Text("Térmico: \(status.thermal.label)").foregroundStyle(status.thermalIsWarning ? .red : .primary)
            Spacer()
            if let display = app.programOutputDisplay,
               let name = app.outputDisplays.first(where: { $0.id == display })?.name {
                Label("Salida: \(name)", systemImage: "display").foregroundStyle(.red)
            }
            if let url = app.projectURL { Text(url.lastPathComponent).foregroundStyle(.secondary) }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estado")
    }
}
