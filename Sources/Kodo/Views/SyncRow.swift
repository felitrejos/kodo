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
                .opacity(model.isSyncPaused ? 0.5 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Speaker Sync")
                    .bold()
                HStack(spacing: 4) {
                    GroupMenu(model: model)
                    Text("·")
                    Text(status)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Speaker Sync", isOn: Binding(get: { model.settings.syncEnabled }, set: { model.setSyncOn($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private var status: String {
        let count = model.activeOutputs.count
        if model.isSyncPaused {
            return "Waiting for its speakers"
        }
        guard model.isSyncOn else {
            return "Off"
        }
        switch count {
        case 0: return "Choose its speakers"
        case 1: return "1 speaker"
        default: return "\(count) in sync"
        }
    }
}
