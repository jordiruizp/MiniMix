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
                TransitionControls(app: app)
                MonitorPane(app: app, bus: .program)
            }
            .padding(10)
            Divider()
            InputGridView(app: app)
            Divider()
            HSplitView {
                PlaylistPanel(app: app).frame(minWidth: 420, maxHeight: .infinity, alignment: .top)
                MixerPanel(mixer: app.mixer).frame(minWidth: 300, maxHeight: .infinity, alignment: .top)
            }
            .frame(minHeight: 230)
            Divider()
            StatusBarView(app: app)
        }
        .frame(minWidth: 1100, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(KeyboardShortcutMonitor(app: app))
        .alert("MiniMix", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        .task { app.start() }
    }
}
