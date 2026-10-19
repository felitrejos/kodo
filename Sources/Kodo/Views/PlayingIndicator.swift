import SwiftUI

/// A small waveform that moves while an app is making sound.
struct PlayingIndicator: View {
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "waveform")
            .font(.caption)
            .foregroundStyle(.secondary)
            .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: isPlaying && !reduceMotion)
            .opacity(isPlaying ? 1 : 0)
            .accessibilityLabel("Playing")
            .accessibilityHidden(!isPlaying)
    }
}
