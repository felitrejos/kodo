import SwiftUI

struct AppRow: View {
    let model: KodoModel
    let app: AudioApp

    var body: some View {
        let isMuted = model.isMuted(app)
        RowLayout(
            icon: .app(app.icon),
            name: app.name,
            detail: app.isPlaying ? nil : "Not playing",
            isDimmed: !app.isPlaying,
            toggle: SoundToggle(
                title: isMuted ? "Unmute \(app.name)" : "Mute \(app.name)",
                isOn: !isMuted,
                level: Double(model.volume(for: app)),
                offStyle: .red,
                action: toggleMute)
        ) {
            LevelSlider(
                title: "Volume for \(app.name)",
                value: Double(model.volume(for: app)),
                isDimmed: isMuted,
                onChange: setVolume)
        }
    }

    private func toggleMute() {
        model.toggleMute(app)
    }

    private func setVolume(_ volume: Double) {
        model.setVolume(Float(volume), for: app)
    }
}
