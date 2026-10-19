import SwiftUI

/// A rounded Liquid Glass platter, like Control Center's modules.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.rowSpacing) {
            content
        }
        .padding(Design.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Design.cardCornerRadius))
    }
}
