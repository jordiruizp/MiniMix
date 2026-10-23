import Core
import SwiftUI

/// Columna central: T-bar, CUT y FADE con selector de duración.
struct TransitionControls: View {
    let app: AppViewModel
    static let fadePresets: [Double] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5]

    var body: some View {
        VStack(spacing: 10) {
            TBar(axis: .vertical, progress: app.transitionProgress) { app.send(.tbar($0)) }
                .frame(width: 44, height: 150)
            Button { app.send(.cut) } label: {
                Text("CUT").font(.headline).frame(width: 96)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .accessibilityHint("Pasa Preview a Programa al instante (Espacio)")
            Menu {
                ForEach(Self.fadePresets, id: \.self) { seconds in
                    Button(Formatting.seconds(seconds)) { app.fadeDuration = seconds }
                }
            } label: {
                Text("FADE \(Formatting.seconds(app.fadeDuration))").font(.headline)
            } primaryAction: {
                app.send(.fade(duration: app.fadeDuration))
            }
            .menuStyle(.button)
            .frame(width: 120)
            .accessibilityLabel("Fundido de \(Formatting.seconds(app.fadeDuration))")
            .accessibilityHint("Clic: fundido (Intro). Flecha: elegir duración")
            Stepper(value: Binding(get: { app.fadeDuration }, set: { app.fadeDuration = $0 }),
                    in: 0.1...5, step: 0.1) {
                Text("Duración").font(.caption)
            }
            .accessibilityLabel("Duración del fundido")
        }
        .padding(.top, 20)
    }
}

/// T-bar: arrastrar envía la posición absoluta 0…1; al llegar a 1 vuelve a 0.
struct TBar: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    /// Progreso de una transición en curso (para reflejar un fade automático).
    let progress: Double?
    let onChange: (Double) -> Void
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let length = axis == .vertical ? geo.size.height : geo.size.width
            let value = dragValue ?? progress ?? 0
            ZStack(alignment: axis == .vertical ? .top : .leading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                    .frame(width: axis == .vertical ? geo.size.width - 8 : 14,
                           height: axis == .vertical ? 14 : geo.size.height - 8)
                    .offset(x: axis == .vertical ? 4 : value * (length - 14),
                            y: axis == .vertical ? value * (length - 14) : 4)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let position = axis == .vertical ? drag.location.y : drag.location.x
                let newValue = min(max(position / length, 0), 1)
                dragValue = newValue
                onChange(newValue)
            }.onEnded { _ in
                dragValue = nil
            })
        }
        .accessibilityElement()
        .accessibilityLabel("T-bar")
        .accessibilityValue("\(Int(((dragValue ?? progress ?? 0) * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            let current = dragValue ?? progress ?? 0
            let next = direction == .increment ? min(current + 0.1, 1) : max(current - 0.1, 0)
            onChange(next)
        }
    }
}
