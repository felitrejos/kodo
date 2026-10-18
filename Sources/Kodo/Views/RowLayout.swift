import SwiftUI

/// The shared shape of every row: icon, name over a detail line, the sound toggle, and a
/// slider. Speakers and apps line up in the same columns.
struct RowLayout<Slider: View>: View {
    let icon: RowIcon.Content
    let name: String
    let detail: String?
    var detailStyle: Color = .secondary
    var isDimmed = false
    let toggle: SoundToggle
    @ViewBuilder let slider: Slider

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(content: icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailStyle)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(width: Design.nameWidth, alignment: .leading)

            toggle
            slider
                .frame(maxWidth: .infinity)
        }
        .opacity(isDimmed ? 0.5 : 1)
        .frame(height: Design.rowHeight)
    }
}
