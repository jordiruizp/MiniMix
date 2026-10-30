import Core
import SwiftUI

/// Escena Settings (⌘,): lienzo y fps del proyecto, fundido por defecto, latencia de audio,
/// eficiencia y App Nap.
public struct PreferencesView: View {
    let app: AppViewModel

    public init(app: AppViewModel) { self.app = app }

    public var body: some View {
        Form {
            Section("Lienzo del proyecto") {
                Picker("Resolución", selection: canvasPreset) {
                    ForEach(Preferences.CanvasPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frecuencia", selection: frameRate) {
                    ForEach(Preferences.frameRates, id: \.self) { Text(Preferences.label(for: $0)).tag($0) }
                }
                if app.isExperimentalCanvas {
                    Label("4K es experimental en este equipo: más memoria, GPU y calor.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
            }
            Section("Transiciones") {
                Stepper(value: preference(\.defaultFadeDuration), in: ModelLimits.switcherFade, step: 0.1) {
                    Text("Fundido por defecto: \(Formatting.seconds(app.preferences.defaultFadeDuration))")
                }
                .accessibilityValue(Formatting.seconds(app.preferences.defaultFadeDuration))
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
            if prefs.defaultFadeDuration != app.preferences.defaultFadeDuration { app.fadeDuration = prefs.defaultFadeDuration }
            app.preferences = prefs
        })
    }

    private var canvasPreset: Binding<Preferences.CanvasPreset> {
        Binding(get: { Preferences.CanvasPreset(size: app.project.canvas.size) ?? app.preferences.canvasPreset },
                set: { app.setCanvas(CanvasFormat(size: $0.size, frameRate: app.project.canvas.frameRate)) })
    }

    private var frameRate: Binding<FrameRate> {
        Binding(get: { app.project.canvas.frameRate },
                set: { app.setCanvas(CanvasFormat(size: app.project.canvas.size, frameRate: $0)) })
    }
}
