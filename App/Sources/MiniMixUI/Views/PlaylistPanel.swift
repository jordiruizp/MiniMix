import Core
import SwiftUI

/// Panel de playlist de la entrada seleccionada (T51).
struct PlaylistPanel: View {
    let app: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let input = app.selectedInput, let playlist = input.content.playlist {
                PlaylistHeader(model: app.playlists, input: input, isPlaying: app.isPlaying(input.id))
                PlaylistSettings(model: app.playlists, id: input.id, playlist: playlist)
                PlaylistItemList(model: app.playlists, id: input.id, playlist: playlist)
            } else {
                Text("Playlist").font(.headline)
                Text("Selecciona una entrada de tipo playlist para editarla.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
    }
}

private struct PlaylistHeader: View {
    let model: PlaylistViewModel
    let input: InputDescriptor
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(input.name).font(.headline).lineLimit(1)
            Text(stateLabel).font(.caption).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("Item \(Formatting.remaining(model.itemRemaining(for: input.id)))")
                Text("Total \(Formatting.remaining(model.playlistRemaining(for: input.id)))")
            }
            .font(.caption.monospacedDigit())
            transport
        }
    }

    private var transport: some View {
        HStack(spacing: 2) {
            iconButton("backward.end.fill", "Item anterior") { model.previous(input.id) }
            iconButton(isPlaying ? "pause.fill" : "play.fill", isPlaying ? "Pausar" : "Reproducir") {
                model.togglePlay(input.id)
            }
            iconButton("forward.end.fill", "Item siguiente") { model.next(input.id) }
            iconButton("arrow.counterclockwise", "Reiniciar item") { model.restartItem(input.id) }
        }
        .buttonStyle(.bordered)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help(label)
            .accessibilityLabel(label)
    }

    private var stateLabel: String {
        switch model.state(for: input.id) {
        case .idle: "Parada"
        case .playing: isPlaying ? "Reproduciendo" : "En pausa"
        case .held: "En espera"
        case .ended: "Terminada"
        }
    }
}

private struct PlaylistSettings: View {
    let model: PlaylistViewModel
    let id: InputID
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 10) {
            Picker("Modo", selection: Binding(get: { playlist.mode }, set: { model.setMode($0, in: id) })) {
                Text("Continuo").tag(PlaybackMode.continuous)
                Text("Parar tras cada item").tag(PlaybackMode.stopAfterEach)
            }
            .fixedSize()
            Toggle("Bucle", isOn: Binding(get: { playlist.loop }, set: { model.setLoop($0, in: id) }))
            Picker("Al parar", selection: Binding(get: { playlist.holdBehavior },
                                                  set: { model.setHoldBehavior($0, in: id) })) {
                Text("Último fotograma").tag(HoldBehavior.lastFrame)
                Text("Negro").tag(HoldBehavior.black)
                Text("Primer fotograma del siguiente").tag(HoldBehavior.nextFirstFrame)
            }
            .fixedSize()
            Picker("Transición", selection: Binding(get: { isFade }, set: { setFade($0) })) {
                Text("Corte").tag(false)
                Text("Fundido").tag(true)
            }
            .fixedSize()
            if case .fade(let seconds) = playlist.itemTransition {
                Slider(value: Binding(get: { seconds }, set: { model.setTransition(.fade(seconds: $0), in: id) }),
                       in: 0...2, step: 0.1)
                    .frame(width: 90)
                    .accessibilityLabel("Duración del fundido entre items")
                Text(Formatting.seconds(seconds)).font(.caption.monospacedDigit())
            }
        }
        .font(.callout)
        .controlSize(.small)
    }

    private var isFade: Bool {
        if case .fade = playlist.itemTransition { return true }
        return false
    }

    private func setFade(_ fade: Bool) {
        model.setTransition(fade ? .fade(seconds: 0.5) : .cut, in: id)
    }
}

private struct PlaylistItemList: View {
    let model: PlaylistViewModel
    let id: InputID
    let playlist: Playlist

    var body: some View {
        let current = model.currentIndex(for: id)
        let next = model.nextIndex(for: id)
        List {
            ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                PlaylistItemRow(model: model, id: id, item: item, index: index,
                                isCurrent: index == current, isNext: index == next)
                    .listRowBackground(rowBackground(isCurrent: index == current, isNext: index == next))
            }
            .onMove { model.moveItems(in: id, from: $0, to: $1) }
            .onDelete { model.removeItems(in: id, at: $0) }
            .dropDestination(for: URL.self) { urls, index in
                model.addItems(in: id, from: urls, at: index)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .dropDestination(for: URL.self) { urls, _ in model.addItems(in: id, from: urls) > 0 }
        .contextMenu {
            Button("Añadir color") { model.addColorItem(in: id) }
        }
        .accessibilityLabel("Items de la playlist")
    }

    private func rowBackground(isCurrent: Bool, isNext: Bool) -> Color {
        if isCurrent { return .red.opacity(0.25) }
        if isNext { return .green.opacity(0.18) }
        return .clear
    }
}

private struct PlaylistItemRow: View {
    let model: PlaylistViewModel
    let id: InputID
    let item: PlaylistItem
    let index: Int
    let isCurrent: Bool
    let isNext: Bool

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { item.enabled }, set: { model.setEnabled($0, item: item.id, in: id) }))
                .labelsHidden()
                .accessibilityLabel("Activar item \(index + 1)")
            Text("\(index + 1)").font(.caption.monospacedDigit()).frame(width: 18)
            Image(systemName: isCurrent ? "play.fill" : item.source.symbolName)
                .foregroundStyle(isCurrent ? .red : (isNext ? .green : .secondary))
            Text(item.source.displayName).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(item.enabled ? .primary : .tertiary)
            Spacer()
            if item.source.isStill {
                numberField("Duración", value: item.duration) { model.setDuration($0, item: item.id, in: id) }
            } else {
                numberField("In", value: item.inPoint) {
                    model.setTrim(inPoint: $0, outPoint: item.outPoint, item: item.id, in: id)
                }
                numberField("Out", value: item.outPoint) {
                    model.setTrim(inPoint: item.inPoint, outPoint: $0, item: item.id, in: id)
                }
            }
            Text(Formatting.clock(model.duration(of: item) ?? 0)).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            Toggle("Parar después", isOn: Binding(get: { item.stopAfter },
                                                  set: { model.setStopAfter($0, item: item.id, in: id) }))
                .toggleStyle(.button).controlSize(.small)
                .help("Parar después de este item")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.jump(id, to: item.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Item \(index + 1): \(item.source.displayName)\(isCurrent ? ", actual" : isNext ? ", siguiente" : "")")
        .accessibilityAction(named: "Saltar a este item") { model.jump(id, to: item.id) }
    }

    private func numberField(_ title: String, value: Double?, set: @escaping @MainActor @Sendable (Double?) -> Void) -> some View {
        TextField(title, value: Binding(get: { value }, set: { set($0) }), format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 52)
            .controlSize(.small)
            .help("\(title) (s)")
            .accessibilityLabel("\(title) en segundos")
    }
}
