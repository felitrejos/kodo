import SwiftUI

/// The Speaker Sync switch. It only decides whether several speakers play together; app
/// volumes work either way.
struct SyncRow: View {
    let model: KodoModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.isSyncOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: Design.chipSize, height: Design.chipSize)
                .background(model.isSyncOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Speaker Sync")
                    .bold()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Toggle("Speaker Sync", isOn: Binding(get: { model.isSyncOn }, set: { model.setSyncOn($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(model.activeOutputs.isEmpty && !model.isSyncOn)
        }
    }

    private var status: String {
        let count = model.activeOutputs.count
        guard model.isSyncOn else {
            return count < 2 ? "Play through several speakers at once" : "Off · \(count) speakers ready"
        }
        return count == 1 ? "On · 1 speaker" : "On · \(count) speakers in sync"
    }
}
