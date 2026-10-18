import SwiftUI

/// The facts about one device, in a small popover.
struct DeviceInspector: View {
    let model: KodoModel
    let output: AudioDevice

    @State private var details: DeviceDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DeviceChip(title: output.name, symbol: output.symbolName, isActive: model.isActive(output), action: {})
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.name)
                        .font(.headline)
                    if let manufacturer = details?.manufacturer {
                        Text(manufacturer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let details {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    InspectorRow(label: "Connection", value: details.connection)
                    GridRow {
                        Text("Sample rate")
                            .foregroundStyle(.secondary)
                        SampleRatePicker(details: details, choose: setSampleRate)
                    }
                    InspectorRow(label: "Format", value: format(details))
                    InspectorRow(label: "Channels", value: channels(details))
                    if let latency = details.reportedLatency {
                        InspectorRow(label: "Reported delay", value: milliseconds(latency))
                    }
                    InspectorRow(label: "Measured", value: measured)
                    if model.isSyncOn, model.isSelected(output) {
                        GridRow {
                            Text("Nudge")
                                .foregroundStyle(.secondary)
                            NudgeControl(trim: model.trim(for: output), nudge: nudge)
                        }
                    }
                }
                .font(.callout)
            }

            Divider()
            Toggle("Hide from Kodo", isOn: Binding(get: { model.isHidden(output) }, set: { model.setHidden($0, for: output) }))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(16)
        .frame(width: 280)
        .task(id: output.id, loadDetails)
    }

    private var measured: String {
        guard let measurement = model.measurement(for: output) else {
            return "Not calibrated"
        }
        return "\(milliseconds(measurement.latency)) to the mic"
    }

    private func format(_ details: DeviceDetails) -> String {
        guard let bits = details.bitDepth else {
            return "Unknown"
        }
        return "\(bits)-bit \(details.isFloat ? "float" : "integer")"
    }

    private func channels(_ details: DeviceDetails) -> String {
        let outputs = details.outputChannels == 1 ? "Mono" : details.outputChannels == 2 ? "Stereo" : "\(details.outputChannels) channels"
        return details.inputChannels > 0 ? "\(outputs) · \(details.inputChannels) in" : outputs
    }

    private func milliseconds(_ seconds: Double) -> String {
        "\((seconds * 1000).formatted(.number.precision(.fractionLength(0)))) ms"
    }

    private func loadDetails() async {
        details = DeviceDetails(device: output)
    }

    private func setSampleRate(_ rate: Double) {
        model.setSampleRate(rate, for: output)
        details = DeviceDetails(device: output)
    }

    private func nudge(_ seconds: Double) {
        model.nudge(output, by: seconds)
    }
}
