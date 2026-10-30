import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

/// Rejilla de entradas con tarjetas; admite soltar archivos desde Finder.
struct InputGridView: View {
    let app: AppViewModel
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(app.project.inputs.enumerated()), id: \.element.id) { index, input in
                    InputCard(app: app, input: input, number: index + 1)
                }
                AddInputButton(app: app)
                if app.project.inputs.isEmpty { emptyState }
            }
            .padding(10)
        }
        .frame(height: 168)
        .background(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .overlay(Label("Suelta para añadir entradas", systemImage: "plus.rectangle.on.rectangle")
                        .font(.headline).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            app.addInputs(from: urls) > 0
        } isTargeted: { isDropTargeted = $0 }
        .accessibilityLabel("Rejilla de entradas")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sin entradas", systemImage: "rectangle.stack.badge.plus").font(.headline)
            Text("Arrastra aquí vídeos, audio o imágenes desde Finder, o pulsa + para añadir archivos, un color o una playlist.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 360, height: 120, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AddInputButton: View {
    let app: AppViewModel

    var body: some View {
        Menu {
            Button("Archivos…") { openFiles() }
            Button("Color") { app.addColorInput() }
            Button("Playlist") { app.addPlaylistInput() }
                .disabled(app.playlistsUnavailableReason != nil)
                .help(app.playlistsUnavailableReason ?? "Añadir una entrada de playlist")
            if let reason = app.playlistsUnavailableReason {
                Text(reason).font(.caption)
            }
        } label: {
            Image(systemName: "plus").font(.title)
                .frame(width: 60, height: 120)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 60, height: 120)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4])))
        .accessibilityLabel("Añadir entrada")
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .image]
        if panel.runModal() == .OK { app.addInputs(from: panel.urls) }
    }
}

/// Tarjeta: miniatura · nombre · tiempo restante · ▶ · borde (verde PVW, rojo PGM).
struct InputCard: View {
    let app: AppViewModel
    let input: InputDescriptor
    let number: Int
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isEditingColor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                InputThumbnail(input: input)
                    .frame(width: 176, height: 99)
                Text("\(number)").font(.caption.bold()).padding(4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white).padding(4)
                if input.kind == .playlist {
                    Image(systemName: "list.bullet.rectangle").padding(6)
                        .frame(maxWidth: .infinity, alignment: .trailing).foregroundStyle(.white)
                }
            }
            HStack(spacing: 4) {
                Text(input.name).font(.callout).lineLimit(1)
                Spacer(minLength: 2)
                RemainingTimeLabel(app: app, id: input.id).foregroundStyle(.secondary)
                if input.kind != .color && input.kind != .image {
                    Button { togglePlay() } label: {
                        Image(systemName: app.isPlaying(input.id) ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(app.isPlaying(input.id) ? "Pausar \(input.name)" : "Reproducir \(input.name)")
                }
            }
            .frame(width: 176)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: borderColor == .clear ? 0 : 3))
        .contentShape(Rectangle())
        .onTapGesture { app.selectInput(input.id) }
        .contextMenu { InputContextMenu(app: app, input: input, isRenaming: $isRenaming, newName: $newName,
                                        isEditingColor: $isEditingColor) }
        .alert("Renombrar entrada", isPresented: $isRenaming) {
            TextField("Nombre", text: $newName)
            Button("Renombrar") { app.rename(input.id, to: newName) }
            Button("Cancelar", role: .cancel) {}
        }
        .popover(isPresented: $isEditingColor) { ColorEditor(app: app, input: input) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Entrada \(number): \(input.name), \(input.kind.localizedName)\(busDescription)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.selectInput(input.id) }
        .accessibilityAction(named: "Poner en Preview") { app.selectInput(input.id) }
        .accessibilityAction(named: app.isPlaying(input.id) ? "Pausar" : "Reproducir") { togglePlay() }
        .accessibilityAction(named: "Renombrar") {
            newName = input.name
            isRenaming = true
        }
    }

    private var isSelected: Bool { app.selectedInputID == input.id }

    private var borderColor: Color {
        if app.project.program == input.id { return Theme.program }
        if app.project.preview == input.id { return Theme.preview }
        return .clear
    }

    private var busDescription: String {
        if app.project.program == input.id { return ", en Programa" }
        if app.project.preview == input.id { return ", en Preview" }
        return ""
    }

    private func togglePlay() {
        app.send(app.isPlaying(input.id) ? .pause(input.id) : .play(input.id))
    }
}

/// Menú contextual de una entrada.
struct InputContextMenu: View {
    let app: AppViewModel
    let input: InputDescriptor
    @Binding var isRenaming: Bool
    @Binding var newName: String
    @Binding var isEditingColor: Bool

    var body: some View {
        Button("Poner en Preview") { app.selectInput(input.id) }
        if input.kind != .color && input.kind != .image {
            Button(app.isPlaying(input.id) ? "Pausar" : "Reproducir") {
                app.send(app.isPlaying(input.id) ? .pause(input.id) : .play(input.id))
            }
            Button("Reiniciar") { app.send(.restart(input.id)) }
        }
        Divider()
        Button("Renombrar…") {
            newName = input.name
            isRenaming = true
        }
        if input.kind == .color {
            Button("Color…") { isEditingColor = true }
        }
        if input.kind == .video || input.kind == .audio {
            Toggle("Bucle", isOn: Binding(get: { input.loop }, set: { app.send(.setLoop(input.id, $0)) }))
        }
        Picker("Ajuste", selection: Binding(get: { input.fit }, set: { app.setFit($0, for: input.id) })) {
            Text("Encajar (fit)").tag(FitMode.fit)
            Text("Rellenar (fill)").tag(FitMode.fill)
            Text("Estirar (stretch)").tag(FitMode.stretch)
        }
        if input.kind.hasAudio {
            Toggle("Audio sigue a Programa", isOn: Binding(
                get: { input.audioFollowsProgram },
                set: { app.send(.setAudioFollowsProgram(input.id, $0)) }))
        }
        if let path = input.content.mediaReference?.path {
            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Divider()
        Button("Quitar", role: .destructive) { app.removeInput(input.id) }
            .disabled(app.isInTransition(input.id))
    }
}

/// Selector de color con campo hexadecimal para entradas de color.
struct ColorEditor: View {
    let app: AppViewModel
    let input: InputDescriptor
    @State private var hex = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color de «\(input.name)»").font(.headline)
            ColorPicker("Color", selection: Binding(get: { current.swiftUIColor },
                                                    set: { apply(RGBAColor($0)) }), supportsOpacity: false)
            HStack {
                TextField("#RRGGBB", text: $hex)
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                    .onSubmit { if let color = RGBAColor(hex: hex) { apply(color) } }
                    .accessibilityLabel("Color en hexadecimal")
                Button("Aplicar") { if let color = RGBAColor(hex: hex) { apply(color) } }
                    .disabled(RGBAColor(hex: hex) == nil)
            }
        }
        .padding()
        .onAppear { hex = current.hexString }
    }

    private var current: RGBAColor {
        if case .color(let color) = app.descriptor(input.id)?.content { return color }
        return .black
    }

    private func apply(_ color: RGBAColor) {
        app.setColor(color, for: input.id)
        hex = color.hexString
    }
}
