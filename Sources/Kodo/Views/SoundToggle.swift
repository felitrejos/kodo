import SwiftUI

/// The speaker glyph that switches sound on and off for a row. While on, its waves show the
/// level; while off, it's a slashed speaker.
struct SoundToggle: View {
    let title: String
    let isOn: Bool
    let level: Double
    /// Muting an app is unusual and worth noticing; a speaker left out of the mix is not.
    var offStyle: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "speaker.wave.3.fill" : "speaker.slash.fill", variableValue: isOn ? level : nil)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isOn ? .secondary : offStyle)
                .font(.system(size: 13))
                .frame(width: Design.toggleSize, height: Design.toggleSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}
