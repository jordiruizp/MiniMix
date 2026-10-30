import AppKit
import Core
import SwiftUI

/// Ventana principal (sección 7 del plan): monitores + T-bar, rejilla, playlist + mixer, estado.
public struct RootView: View {
    let app: AppViewModel

    public init(app: AppViewModel) { self.app = app }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                MonitorPane(app: app, bus: .preview)
                TransitionControls(app: app).focusSection()
                MonitorPane(app: app, bus: .program)
            }
            .padding(10)
            Divider()
            InputGridView(app: app).focusSection()
            Divider()
            HSplitView {
                PlaylistPanel(app: app).frame(minWidth: 420, maxHeight: .infinity, alignment: .top)
                    .focusSection()
                MixerPanel(mixer: app.mixer).frame(minWidth: 300, maxHeight: .infinity, alignment: .top)
                    .focusSection()
            }
            .frame(minHeight: 230)
            Divider()
            StatusBarView(app: app)
        }
        .frame(minWidth: 1100, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(DocumentEditedMarker(edited: app.hasUnsavedChanges))
        .navigationTitle(app.documentName)
        .modifier(KeyboardShortcutMonitor(app: app))
        .alert("MiniMix", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        .alert("Archivos no encontrados", isPresented: Binding(
            get: { !app.missingReferences.isEmpty && app.errorMessage == nil },
            set: { if !$0 { app.missingReferences = [] } })) {
            Button("Elegir carpeta…") { chooseRelinkFolder() }
            Button("Ahora no", role: .cancel) {}
        } message: {
            Text(Self.missingMessage(app.missingReferences))
        }
        .sheet(isPresented: Binding(get: { app.isEditingProjectFormat },
                                    set: { app.isEditingProjectFormat = $0 })) {
            ProjectFormatSheet(app: app)
        }
        .task { app.start() }
    }

    static func missingMessage(_ missing: [MediaReference]) -> String {
        let names = missing.prefix(5).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        let more = missing.count > 5 ? " y \(missing.count - 5) más" : ""
        return "Faltan \(missing.count) archivo(s): \(names.joined(separator: ", "))\(more). "
            + "Elige la carpeta donde están ahora para reenlazarlos."
    }

    private func chooseRelinkFolder() {
        let missing = app.missingReferences
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Carpeta con los archivos que faltan"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            let relinked = await app.relinkMissing(in: folder)
            if relinked == 0 { app.errorMessage = "No se encontró ninguno de los \(missing.count) archivo(s) en esa carpeta." }
        }
    }
}

/// Refleja los cambios sin guardar en la ventana (punto del botón de cierre).
private struct DocumentEditedMarker: NSViewRepresentable {
    let edited: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        view.window?.isDocumentEdited = edited
    }
}
