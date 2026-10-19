import SwiftUI

struct HeaderView: View {
    let model: KodoModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("Kodo")
                .font(.headline)
            Spacer()
            MoreMenu(model: model)
        }
        .padding(.horizontal, 4)
    }
}
