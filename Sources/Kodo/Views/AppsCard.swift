import SwiftUI

struct AppsCard: View {
    let model: KodoModel

    var body: some View {
        Card {
            Text("Apps")
                .bold()
                .accessibilityAddTraits(.isHeader)
            let apps = model.visibleApps
            if apps.isEmpty {
                Text("Apps show up here while they play sound.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    AppRow(model: model, app: app)
                }
            }
            if model.hiddenAppCount > 0 {
                Button(model.showsHiddenApps ? "Hide Hidden Apps" : "Show \(model.hiddenAppCount) Hidden", action: toggleHidden)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleHidden() {
        withAnimation(Design.animation) {
            model.showsHiddenApps.toggle()
        }
    }
}
