import SwiftUI

struct AppRow: View {
    let model: KodoModel
    let app: AudioApp

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Design.appIconSize, height: Design.appIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .lineLimit(1)
                    PlayingIndicator(isPlaying: app.isPlaying)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu("Play \(app.name) Through", systemImage: model.route(for: app)?.symbolName ?? "arrow.triangle.branch") {
                RouteMenu(model: model, app: app)
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
            .opacity(isHovering || model.route(for: app) != nil ? 1 : 0)
            .help("Choose where \(app.name) plays")
            CapsuleSlider(
                title: app.name,
                value: model.sliderValue(for: app),
                isMuted: model.isMuted(app),
                showsGlyph: true,
                onToggleMute: toggleMute,
                marker: model.isBoosted(app) ? 0.5 : nil,
                onChange: setVolume)
            .frame(width: Design.rowSliderWidth + 8)
        }
        .opacity(app.isPlaying ? 1 : 0.6)
        .contentShape(.rect)
        .onHover(perform: setHovering)
        .contextMenu {
            Menu("Play Through") {
                RouteMenu(model: model, app: app)
            }
            Toggle("Boost to 200%", isOn: Binding(get: { model.isBoosted(app) }, set: { model.setBoosted($0, for: app) }))
            Divider()
            Button("Reset", systemImage: "arrow.counterclockwise", action: reset)
        }
    }

    private var detail: String? {
        if let route = model.route(for: app) {
            return "On \(route.name)"
        }
        if model.isBoosted(app) {
            return "Boosted"
        }
        return app.isPlaying ? nil : "Paused"
    }

    private func toggleMute() {
        model.toggleMute(app)
    }

    private func setVolume(_ position: Double) {
        model.setSliderValue(position, for: app)
    }

    private func setHovering(_ hovering: Bool) {
        isHovering = hovering
    }

    private func reset() {
        model.reset(app)
    }
}
