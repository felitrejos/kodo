import SwiftUI

/// The leading icon of a row: an app's own icon, or a device glyph on a soft circle that
/// fills with the accent color while the speaker is in the mix.
struct RowIcon: View {
    enum Content {
        case app(NSImage)
        case device(symbol: String, isActive: Bool)
    }

    let content: Content

    var body: some View {
        switch content {
        case .app(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: Design.iconSize, height: Design.iconSize)
                .accessibilityHidden(true)
        case .device(let symbol, let isActive):
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? .white : .secondary)
                .frame(width: Design.iconSize, height: Design.iconSize)
                .background(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
                .accessibilityHidden(true)
        }
    }
}
