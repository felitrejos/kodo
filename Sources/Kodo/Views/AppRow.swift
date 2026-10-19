import SwiftUI

struct AppRow: View {
    let model: KodoModel
    let app: AudioApp

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Design.appIconSize, height: Design.appIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .lineLimit(1)
                if !app.isPlaying {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            CapsuleSlider(
                title: app.name,
                value: Double(model.volume(for: app)),
                isMuted: model.isMuted(app),
                showsGlyph: true,
                onToggleMute: toggleMute,
                onChange: setVolume)
            .frame(width: Design.rowSliderWidth + 20)
        }
        .opacity(app.isPlaying ? 1 : 0.6)
        .contextMenu {
            Button("Reset Volume", systemImage: "arrow.counterclockwise", action: reset)
        }
    }

    private func toggleMute() {
        model.toggleMute(app)
    }

    private func setVolume(_ volume: Double) {
        model.setVolume(Float(volume), for: app)
    }

    private func reset() {
        model.reset(app)
    }
}
