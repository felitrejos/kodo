import SwiftUI

struct HeaderView: View {
    let model: KodoModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kodo")
                    .font(.headline)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Toggle("Kodo", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.activeOutputs.isEmpty)
        }
    }

    private var status: String {
        let count = model.activeOutputs.count
        guard model.isOn else {
            return count == 0 ? "Choose speakers to play through" : "Off · audio plays as usual"
        }
        return count == 1 ? "Playing through 1 speaker" : "In sync on \(count) speakers"
    }
}
