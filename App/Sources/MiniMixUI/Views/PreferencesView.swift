import Core
import SwiftUI

/// Escena Settings (⌘,): **valores por defecto** para proyectos nuevos (lienzo, fps, fundido),
/// salida y latencia de audio, eficiencia y App Nap. No modifica el proyecto abierto: su formato se cambia
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
            Section {
                Toggle("Reproducir vídeos automáticamente al pasar a Programa (y pausarlos al salir)",
                       isOn: preference(\.autoPlayVideoOnProgram))
            } header: {
                Text("Reproducción")
            } footer: {
                Text("Al cortar o iniciar una transición hacia un vídeo en pausa, se pone en marcha solo; "
                     + "al salir de Programa se pausa cuando la transición termina. Una playlist arranca "
                     + "también si su item en curso es un vídeo; al terminar, siguen mandando sus opciones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                let options = AudioOutputOptions(available: app.audioOutputs,
                                                 selectedUID: app.preferences.audioOutputDeviceUID,
                                                 selectedName: app.preferences.audioOutputDeviceName)
                Picker("Salida de audio", selection: audioOutputSelection) {
                    ForEach(options.entries) { entry in
                        Text(entry.label).tag(entry.uid)
                    }
                }
                Text("A qué dispositivo se envía la mezcla: la salida que use el sistema (p. ej. el HDMI "
                     + "de la pantalla), el jack de auriculares, los altavoces… Las salidas se detectan "
                     + "al arrancar MiniMix.")
                    .font(.caption).foregroundStyle(.secondary)
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

    /// Selección de la salida de audio: guarda también el nombre (para mostrar «no conectado»
    /// si en otro arranque el dispositivo ya no está).
    private var audioOutputSelection: Binding<String?> {
        Binding(get: { app.preferences.audioOutputDeviceUID }, set: { uid in
            var prefs = app.preferences
            prefs.audioOutputDeviceUID = uid
            prefs.audioOutputDeviceName = uid.flatMap { chosen in
                app.audioOutputs.first { $0.uid == chosen }?.name ?? prefs.audioOutputDeviceName
            }
            app.preferences = prefs
        })
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

/// Opciones del picker de salida de audio: «Predeterminada del sistema», las salidas detectadas
/// al arrancar y, si la elegida ya no está entre ellas, una entrada «(no conectado)» que conserva
/// la elección hasta que el usuario cambie a otra.
struct AudioOutputOptions {
    struct Entry: Identifiable {
        /// nil = salida predeterminada del sistema.
        let uid: String?
        let label: String
        var id: String { uid ?? "" }
    }

    let available: [AudioOutputDeviceInfo]
    let selectedUID: String?
    let selectedName: String?

    var entries: [Entry] {
        var result = [Entry(uid: nil, label: "Predeterminada del sistema")]
        result += available.map { Entry(uid: $0.uid, label: $0.name) }
        if let selectedUID, !available.contains(where: { $0.uid == selectedUID }) {
            result.append(Entry(uid: selectedUID, label: "\(selectedName ?? selectedUID) (no conectado)"))
        }
        return result
    }
}

/// Opciones de la hoja Proyecto › Formato…: los preajustes y, si el proyecto tiene un lienzo o
/// una frecuencia no estándar, «Actual (…)» para conservarlos.
struct ProjectFormatOptions {
    enum Size: Hashable {
        case preset(Preferences.CanvasPreset)
        case current(PixelSize)
    }

    let current: CanvasFormat

    var sizes: [Size] {
        var result = Preferences.CanvasPreset.allCases.map(Size.preset)
        if Preferences.CanvasPreset(size: current.size) == nil { result.insert(.current(current.size), at: 0) }
        return result
    }

    var rates: [FrameRate] {
        Preferences.frameRates.contains(current.frameRate)
            ? Preferences.frameRates : [current.frameRate] + Preferences.frameRates
    }

    var initialSize: Size { Preferences.CanvasPreset(size: current.size).map(Size.preset) ?? .current(current.size) }

    func label(_ size: Size) -> String {
        switch size {
        case .preset(let preset): preset.label
        case .current(let pixels): "Actual (\(pixels.width)×\(pixels.height))"
        }
    }

    func label(_ rate: FrameRate) -> String {
        Preferences.frameRates.contains(rate) ? Preferences.label(for: rate) : "Actual (\(Preferences.label(for: rate)))"
    }

    func format(_ size: Size, _ rate: FrameRate) -> CanvasFormat {
        switch size {
        case .preset(let preset): CanvasFormat(size: preset.size, frameRate: rate)
        case .current(let pixels): CanvasFormat(size: pixels, frameRate: rate)
        }
    }

    /// La selección es el formato actual: «Aplicar» no tiene nada que hacer.
    func isCurrent(_ size: Size, _ rate: FrameRate) -> Bool { format(size, rate) == current }
}

/// Proyecto › Formato…: lienzo y fps del proyecto abierto (con confirmación si se está emitiendo).
struct ProjectFormatSheet: View {
    let app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var size: ProjectFormatOptions.Size = .preset(.hd1080)
    @State private var rate: FrameRate = .fps60

    var body: some View {
        let options = ProjectFormatOptions(current: app.project.canvas)
        VStack(alignment: .leading, spacing: 12) {
            Text("Formato del proyecto").font(.headline)
            Picker("Resolución", selection: $size) {
                ForEach(options.sizes, id: \.self) { Text(options.label($0)).tag($0) }
            }
            Picker("Frecuencia", selection: $rate) {
                ForEach(options.rates, id: \.self) { Text(options.label($0)).tag($0) }
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
                    let format = options.format(size, rate)
                    if app.requestProjectFormat(format, confirmWhileLive: ProjectDialogs.confirmFormatChangeWhileLive) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(options.isCurrent(size, rate))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            size = options.initialSize
            rate = options.current.frameRate
        }
    }
}
