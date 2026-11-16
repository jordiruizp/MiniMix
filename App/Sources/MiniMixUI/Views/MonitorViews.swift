import Core
import SwiftUI

/// Sustituto del `MonitorView` de Render: color/nombre de la entrada del bus.
public struct MonitorPlaceholder: View {
    let content: MonitorContent

    public init(content: MonitorContent) { self.content = content }

    public var body: some View {
        ZStack {
            InputThumbnail(input: content.input, large: true)
            if let incoming = content.incoming, content.mix > 0 {
                InputThumbnail(input: incoming, large: true).opacity(content.mix)
            }
        }
    }
}

/// Miniatura de una entrada: color sólido o degradado con icono y nombre.
struct InputThumbnail: View {
    let input: InputDescriptor?
    var large = false

    var body: some View {
        ZStack {
            background
            if let input, input.kind != .color {
                VStack(spacing: large ? 8 : 2) {
                    Image(systemName: input.kind.symbolName)
                        .font(large ? .system(size: 40) : .title3)
                    if large { Text(input.name).font(.title3.weight(.semibold)) }
                }
                .foregroundStyle(.white.opacity(0.85))
            } else if input == nil, large {
                Text("Sin señal").foregroundStyle(.secondary)
            }
        }
        .clipped()
    }

    @ViewBuilder private var background: some View {
        switch input?.content {
        case .color(let color):
            color.swiftUIColor
        case .some(let content):
            LinearGradient(colors: Self.gradient(for: content.kind), startPoint: .topLeading, endPoint: .bottomTrailing)
        case nil:
            Color.black
        }
    }

    static func gradient(for kind: InputKind) -> [Color] {
        switch kind {
        case .video: [.indigo, .purple]
        case .audio: [.teal, .black]
        case .image: [.orange, .pink]
        case .color: [.gray, .gray]
        case .playlist: [.blue, .cyan]
        }
    }
}

/// Tiempo restante de una entrada. Subvista propia: es lo único que depende del refresco de 4 Hz
/// (`AppViewModel.now`), así el monitor o la tarjeta que la contiene no se reevalúan.
struct RemainingTimeLabel: View {
    let app: AppViewModel
    let id: InputID
    var showsUnknown = false

    var body: some View {
        if let remaining = app.remaining(for: id) {
            Text(Formatting.remaining(remaining)).font(.caption.monospacedDigit())
        } else if showsUnknown {
            Text(Formatting.remaining(nil)).font(.caption.monospacedDigit())
        }
    }
}

/// Barra de tiempos sobre el vídeo de Programa: `transcurrido / -restante.frames` centrados
/// (en playlists, del item actual) sobre una franja negra al 70 % pegada al borde inferior.
/// Se redibuja sola con su `TimelineView` a los fps del proyecto; el resto de la interfaz
/// sigue a 4 Hz. La cuenta atrás avisa del final: naranja < 10 s y rojo < 5 s.
struct ProgramTimeOverlay: View {
    let app: AppViewModel
    let id: InputID

    var body: some View {
        if app.hasTransport(id) {
            let fps = app.project.canvas.frameRate.fps
            // Reloj propio al ritmo del proyecto: los frames avanzan suaves sin subir el
            // refresco global (solo se redibuja esta fila de texto, coste inapreciable).
            TimelineView(.periodic(from: .now, by: 1 / max(fps, 1))) { _ in
                let remaining = app.currentItemRemaining(for: id)
                HStack(spacing: 8) {
                    Text(Formatting.elapsed(app.elapsed(for: id)))
                    Text("/").foregroundStyle(.white.opacity(0.55))
                    Text(Formatting.remaining(remaining, fps: fps))
                        .foregroundStyle(Theme.countdown(remaining: remaining) ?? .white)
                }
                .font(.system(size: 20, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.7))
            }
        }
    }
}

/// Monitor PVW o PGM con cabecera de color (verde/rojo) a 16:9.
struct MonitorPane: View {
    let app: AppViewModel
    let bus: MonitorBus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bus == .preview ? "PREVIEW" : "PROGRAMA").font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                Text(input?.name ?? "—").font(.caption).lineLimit(1)
                Spacer()
                if let id = input?.id { RemainingTimeLabel(app: app, id: id, showsUnknown: true) }
            }
            app.monitorFactory.make(content)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    if bus == .program, let id = input?.id { ProgramTimeOverlay(app: app, id: id) }
                }
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(tint, lineWidth: 3))
                .accessibilityElement()
                .accessibilityLabel(bus == .preview ? "Monitor de Preview" : "Monitor de Programa")
                .accessibilityValue(input?.name ?? "Sin señal")
            MonitorTransportBar(app: app, input: input)
        }
    }

    private var tint: Color { bus == .preview ? Theme.preview : Theme.program }
    private var input: InputDescriptor? {
        (bus == .preview ? app.project.preview : app.project.program).flatMap(app.descriptor)
    }

    private var content: MonitorContent {
        guard bus == .program, let progress = app.transitionProgress else {
            return MonitorContent(bus: bus, input: input, incoming: nil, mix: 0)
        }
        let incoming = app.project.preview.flatMap(app.descriptor)
        return MonitorContent(bus: bus, input: input, incoming: incoming, mix: TransitionCurve.videoMix(progress))
    }
}

/// Transporte bajo cada monitor: ir al inicio, reproducir/pausar y parar; en playlists,
/// además item anterior/siguiente. Reserva su altura aunque la entrada no tenga transporte
/// (imagen, color o sin señal) para que los monitores no salten al cambiar de fuente.
struct MonitorTransportBar: View {
    let app: AppViewModel
    let input: InputDescriptor?

    var body: some View {
        HStack(spacing: 2) {
            if let input, app.hasTransport(input.id) {
                let playing = app.isPlaying(input.id)
                let isPlaylist = input.kind == .playlist
                if isPlaylist {
                    button("backward.end.fill", "Item anterior") { app.send(.playlistPrevious(input.id)) }
                }
                button("arrow.counterclockwise", isPlaylist ? "Ir al inicio del item" : "Ir al inicio") {
                    app.goToStart(input.id)
                }
                button(playing ? "pause.fill" : "play.fill", playing ? "Pausar" : "Reproducir") {
                    app.togglePlayback(input.id)
                }
                button("stop.fill", "Parar") { app.stopPlayback(input.id) }
                if isPlaylist {
                    button("forward.end.fill", "Item siguiente") { app.send(.playlistNext(input.id)) }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, minHeight: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transporte de \(input?.name ?? "sin señal")")
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help(label)
            .accessibilityLabel(label)
    }
}
