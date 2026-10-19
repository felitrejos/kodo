import SwiftUI

/// The round device button, Control Center style: filled with the accent color while the
/// speaker is playing, plain while it isn't.
struct DeviceChip: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: Design.chipSize, height: Design.chipSize)
                .background(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(title)
    }
}
