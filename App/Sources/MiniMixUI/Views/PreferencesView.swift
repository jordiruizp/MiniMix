import Core
import SwiftUI

/// Escena Settings (⌘,): **valores por defecto** para proyectos nuevos (lienzo, fps, fundido),
/// latencia de audio, eficiencia y App Nap. No modifica el proyecto abierto: su formato se cambia
/// en Proyecto › Formato… y su fundido en la barra de transición.
public struct PreferencesView: View {
    let app: AppViewModel

    public init(app: AppViewModel) { self.app = app }

    public var body: some View {
        Form {
            Section {
                Picker("Resolución", selection: preference(\.canvasPreset)) {
                    ForEach(Preferences.CanvasPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frecuencia", selection: preference(\.frameRate)) {
                    ForEach(Preferences.frameRates, id: \.self) { Text(Preferences.label(for: $0)).tag($0) }
                }
                if app.preferences.canvasPreset == .uhd4K {
                    Label("4K es experimental en este equipo: más memoria, GPU y calor.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
                Stepper(value: preference(\.defaultFadeDuration), in: ModelLimits.switcherFade, step: 0.1) {
                    Text("Fundido: \(Formatting.seconds(app.preferences.defaultFadeDuration))")
                }
                .accessibilityLabel("Fundido por defecto")
                .accessibilityValue(Formatting.seconds(app.preferences.defaultFadeDuration))
            } header: {
                Text("Proyectos nuevos")
            } footer: {
                Text("Se aplican al proyecto inicial y a Archivo › Proyecto nuevo (⌘N). "
                     + "Para el proyecto abierto usa Proyecto › Formato…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                HStack {
                    Text("Compensación de latencia de salida")
                    Spacer()
                    TextField("ms", value: preference(\.latencyCompensationMs),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Compensación de latencia en milisegundos")
                    Text("ms")
                }
                Text("Retrasa el audio para alinearlo con el vídeo de una pantalla o proyector lento (0–500 ms).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rendimiento y energía") {
                Toggle("Modo eficiencia (monitor de Preview a media frecuencia)", isOn: preference(\.efficiencyMode))
                Toggle("Evitar App Nap y reposo mientras la salida de Programa está activa",
                       isOn: preference(\.preventAppNapWhileLive))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { app.preferences[keyPath: keyPath] }, set: { newValue in
            var prefs = app.preferences
            prefs[keyPath: keyPath] = newValue
            prefs.latencyCompensationMs = Preferences.clamp(prefs.latencyCompensationMs, Preferences.latencyRange)
            app.preferences = prefs
        })
    }
}

/// Proyecto › Formato…: lienzo y fps del proyecto abierto (con confirmación si se está emitiendo).
struct ProjectFormatSheet: View {
    let app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var preset: Preferences.CanvasPreset = .hd1080
    @State private var rate: FrameRate = .fps60

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Formato del proyecto").font(.headline)
            Picker("Resolución", selection: $preset) {
                ForEach(Preferences.CanvasPreset.allCases) { Text($0.label).tag($0) }
            }
            Picker("Frecuencia", selection: $rate) {
                ForEach(Preferences.frameRates, id: \.self) { Text(Preferences.label(for: $0)).tag($0) }
            }
            if app.programOutputDisplay != nil {
                Label("La salida de Programa está activa: el render se reconfigurará.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                Button("Aplicar") {
                    let format = CanvasFormat(size: preset.size, frameRate: rate)
                    if app.requestProjectFormat(format, confirmWhileLive: ProjectDialogs.confirmFormatChangeWhileLive) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            preset = Preferences.CanvasPreset(size: app.project.canvas.size) ?? .hd1080
            rate = app.project.canvas.frameRate
        }
    }
}
