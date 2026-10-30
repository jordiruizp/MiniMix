import Core
import SwiftUI

/// Mixer: un canal por entrada con audio (fader, mute, solo, «sigue a Programa», VU) + Master.
struct MixerPanel: View {
    let mixer: MixerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mixer").font(.headline)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(mixer.channels) { channel in
                        ChannelStrip(mixer: mixer, channel: channel)
                    }
                    Divider()
                    MasterStrip(mixer: mixer)
                }
            }
        }
        .padding(10)
    }
}

private struct ChannelStrip: View {
    let mixer: MixerViewModel
    let channel: MixerViewModel.Channel

    var body: some View {
        VStack(spacing: 4) {
            Text("\(channel.number) \(channel.name)").font(.caption).lineLimit(1).frame(width: 84)
                .foregroundStyle(channel.onProgram ? Theme.program : .primary)
            HStack(alignment: .bottom, spacing: 4) {
                VerticalFader(value: channel.volume) { mixer.setVolume($0, for: channel.id) }
                    .accessibilityLabel("Volumen de \(channel.name)")
                ChannelMeter(mixer: mixer, id: channel.id)
            }
            .frame(height: 110)
            Text(Formatting.decibels(gain: channel.volume)).font(.caption2.monospacedDigit())
            HStack(spacing: 2) {
                ToggleChip(title: "M", isOn: channel.muted, tint: Theme.program, label: "Silenciar \(channel.name)",
                           onText: .white) {
                    mixer.toggleMute(channel.id)
                }
                ToggleChip(title: "S", isOn: channel.solo, tint: .yellow, label: "Solo \(channel.name)") {
                    mixer.toggleSolo(channel.id)
                }
                ToggleChip(title: "PGM", isOn: channel.followsProgram, tint: .orange,
                           label: "Audio de \(channel.name) sigue a Programa") {
                    mixer.setFollowsProgram(!channel.followsProgram, for: channel.id)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quinary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canal \(channel.number): \(channel.name)\(channel.onProgram ? ", en Programa" : "")")
    }
}

private struct MasterStrip: View {
    let mixer: MixerViewModel

    var body: some View {
        VStack(spacing: 4) {
            Text("Master").font(.caption.bold())
            HStack(alignment: .bottom, spacing: 4) {
                VerticalFader(value: mixer.masterVolume) { mixer.setMasterVolume($0) }
                    .accessibilityLabel("Volumen Master")
                ChannelMeter(mixer: mixer, id: nil)
            }
            .frame(height: 110)
            Text(Formatting.decibels(gain: mixer.masterVolume)).font(.caption2.monospacedDigit())
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quinary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canal Master")
    }
}

/// Fader vertical de ganancia lineal 0…2 (1 = 0 dB a la mitad). Arrastre relativo: no salta a la
/// posición del clic. Doble clic → 0 dB.
struct VerticalFader: View {
    let value: Float
    let onChange: (Float) -> Void
    @State private var dragStart: Float?

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(value / 2)
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary).frame(width: 6)
                Capsule().fill(Color.accentColor).frame(width: 6, height: geo.size.height * fraction)
                RoundedRectangle(cornerRadius: 2).fill(.white).shadow(radius: 1)
                    .frame(width: 22, height: 10)
                    .offset(y: -geo.size.height * fraction + 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let start = dragStart ?? value
                dragStart = start
                onChange(Self.value(start: start, deltaY: drag.translation.height, height: geo.size.height))
            }.onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { onChange(1) }
        }
        .frame(width: 26)
        .accessibilityElement()
        .accessibilityValue(Formatting.decibels(gain: value))
        .accessibilityAdjustableAction { direction in
            onChange(direction == .increment ? min(value + 0.05, 2) : max(value - 0.05, 0))
        }
    }

    /// Ganancia tras arrastrar `deltaY` puntos (hacia abajo positivo) en una pista de `height`.
    static func value(start: Float, deltaY: CGFloat, height: CGFloat) -> Float {
        guard height > 0 else { return start }
        return min(max(start - Float(deltaY / height) * 2, 0), 2)
    }
}

/// Vúmetro que solo observa el nivel de su canal (nil = Master).
private struct ChannelMeter: View {
    let mixer: MixerViewModel
    let id: InputID?

    var body: some View { VUMeter(levels: mixer.levels(for: id)) }
}

/// Vúmetro por canal (dBFS −60…0).
struct VUMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array((levels.isEmpty ? [-90, -90] : levels).prefix(2).enumerated()), id: \.offset) { _, level in
                GeometryReader { geo in
                    let fraction = MixerViewModel.meterFraction(level)
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(.black.opacity(0.4))
                        Rectangle()
                            .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                            .mask(alignment: .bottom) {
                                Rectangle().frame(height: geo.size.height * fraction)
                            }
                    }
                }
                .frame(width: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

struct ToggleChip: View {
    let title: String
    let isOn: Bool
    let tint: Color
    let label: String
    var onText: Color = .black
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption2.bold()).frame(minWidth: 18).padding(.horizontal, 3).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? tint : Color.gray.opacity(0.25)))
                .foregroundStyle(isOn ? onText : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "activado" : "desactivado")
    }
}
