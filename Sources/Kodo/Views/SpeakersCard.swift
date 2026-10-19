import SwiftUI

struct SpeakersCard: View {
    let model: KodoModel

    var body: some View {
        Card {
            SyncRow(model: model)
            Divider()
            ForEach(model.listedOutputs) { output in
                DeviceRow(model: model, output: output)
            }
            if model.isSyncOn {
                Divider()
                CalibrateRow(model: model)
            }
            if model.hiddenOutputCount > 0 {
                Button(hiddenTitle, action: toggleHidden)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hiddenTitle: String {
        model.showsHiddenOutputs ? "Hide Hidden Speakers" : "Show \(model.hiddenOutputCount) Hidden"
    }

    private func toggleHidden() {
        withAnimation(Design.animation) {
            model.showsHiddenOutputs.toggle()
        }
    }
}
