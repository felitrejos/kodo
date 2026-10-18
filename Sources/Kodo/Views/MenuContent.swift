import SwiftUI

struct MenuContent: View {
    let model: KodoModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionSpacing) {
            HeaderView(model: model)

            Divider()
            VStack(spacing: Design.rowSpacing) {
                SectionTitle(title: "Speakers")
                ForEach(model.outputs) { output in
                    SpeakerRow(model: model, output: output)
                }
            }

            if model.isOn {
                Divider()
                AppsSection(model: model)
            }

            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            FooterView(model: model)
        }
        .padding(Design.edgePadding)
        .frame(width: Design.menuWidth)
        .animation(Design.animation, value: model.isOn)
    }
}

#Preview("On") {
    MenuContent(model: PreviewData.model())
}

#Preview("Off") {
    MenuContent(model: PreviewData.model(isOn: false))
}
