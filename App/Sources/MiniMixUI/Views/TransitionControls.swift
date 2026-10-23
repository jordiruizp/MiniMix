import Core
import SwiftUI

/// Columna central: T-bar, CUT y FADE con selector de duración.
struct TransitionControls: View {
    let app: AppViewModel
    /// La palanca física; durante un fundido automático (palanca en 0) muestra su progreso.
    private var displayedTBar: Double {
        app.tbarPosition > 0 || app.isDraggingTBar ? app.tbarPosition : app.transitionProgress ?? 0
    }

    static let fadePresets: [Double] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5]

    var body: some View {
        VStack(spacing: 10) {
            TBar(axis: .vertical, position: displayedTBar, onChange: app.moveTBar(to:), onRelease: app.releaseTBar)
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

/// T-bar: el arrastre es relativo (no salta a la posición del clic) y envía la posición absoluta
/// 0…1; al soltar, el ViewModel decide si la palanca vuelve a 0 (rearme).
struct TBar: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    /// Posición mostrada (palanca física o progreso de un fundido automático).
    let position: Double
    let onChange: (Double) -> Void
    let onRelease: () -> Void
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let length = axis == .vertical ? geo.size.height : geo.size.width
            ZStack(alignment: axis == .vertical ? .top : .leading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                    .frame(width: axis == .vertical ? geo.size.width - 8 : 14,
                           height: axis == .vertical ? 14 : geo.size.height - 8)
                    .offset(x: axis == .vertical ? 4 : position * (length - 14),
                            y: axis == .vertical ? position * (length - 14) : 4)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let start = dragStart ?? position
                dragStart = start
                let delta = axis == .vertical ? drag.translation.height : drag.translation.width
                onChange(Self.position(start: start, delta: delta, length: length))
            }.onEnded { _ in
                dragStart = nil
                onRelease()
            })
        }
        .accessibilityElement()
        .accessibilityLabel("T-bar")
        .accessibilityValue("\(Int((position * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            onChange(direction == .increment ? min(position + 0.1, 1) : max(position - 0.1, 0))
            onRelease()
        }
    }

    /// Posición tras arrastrar `delta` puntos desde `start` en una pista de `length` puntos.
    static func position(start: Double, delta: Double, length: Double) -> Double {
        guard length > 0 else { return start }
        return min(max(start + delta / length, 0), 1)
    }
}
