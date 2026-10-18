import SwiftUI

struct AppsSection: View {
    let model: KodoModel

    var body: some View {
        VStack(spacing: Design.rowSpacing) {
            SectionTitle(title: "Apps")
            let apps = model.visibleApps
            if apps.isEmpty {
                Text("Apps show up here when they play sound.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Design.rowHeight, alignment: .leading)
            } else {
                ForEach(apps) { app in
                    AppRow(model: model, app: app)
                }
            }
        }
    }
}
