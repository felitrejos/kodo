import SwiftUI

/// A Control Center style volume slider: a thick capsule that fills from the left. When it
/// has a glyph, the glyph sits inside the fill and works as the mute button.
struct CapsuleSlider: View {
    let title: String
    let value: Double
    var isMuted = false
    /// Shown inside the left end; tapping it calls `onToggleMute`.
    var showsGlyph = false
    var onToggleMute: (() -> Void)?
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let minimumFill = showsGlyph ? Design.sliderHeight : Design.sliderHeight / 2
            let fill = minimumFill + (width - minimumFill) * (isMuted ? 0 : value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.1))
                // White on a darker track, as in Control Center, in both appearances.
                Capsule()
                    .fill(.white.opacity(isMuted ? 0.45 : 1))
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    .frame(width: fill)
                    .animation(Design.animation, value: isMuted)
            }
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let position = (drag.location.x - minimumFill) / max(width - minimumFill, 1)
                        onChange(min(max(position, 0), 1))
                    }
            )
            .overlay(alignment: .leading) {
                if showsGlyph {
                    MuteGlyph(title: title, isMuted: isMuted, level: value, action: toggleMute)
                }
            }
        }
        .frame(height: Design.sliderHeight)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: 0...1) {
                Text(title)
            }
        }
    }

    private func toggleMute() {
        onToggleMute?()
    }
}

/// The speaker inside a slider's fill: gray on the white fill, red and slashed when muted.
private struct MuteGlyph: View {
    let title: String
    let isMuted: Bool
    let level: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: isMuted ? nil : level)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isMuted ? Color.red : Color.black.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Design.sliderHeight + 4, height: Design.sliderHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute \(title)" : "Mute \(title)")
        .help(isMuted ? "Unmute" : "Mute")
    }
}
