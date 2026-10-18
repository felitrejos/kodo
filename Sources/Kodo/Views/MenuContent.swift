import SwiftUI

struct MenuContent: View {
    let model: KodoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(model: model)
            Divider()

            Text("Speakers")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.outputs) { output in
                OutputRow(model: model, output: output)
            }

            Divider()
            CalibrationSection(model: model)

            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit Kodo", action: quit)
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 340)
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private struct Header: View {
    let model: KodoModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kodo")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Play in unison", isOn: Binding(get: { model.isOn }, set: model.setOn))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.activeOutputs.isEmpty)
        }
    }

    private var subtitle: String {
        let count = model.activeOutputs.count
        guard model.isOn else {
            return count == 0 ? "Pick the speakers to play through" : "Off · Mac audio plays normally"
        }
        return count == 1 ? "Playing through 1 speaker" : "Playing through \(count) speakers in unison"
    }
}

private struct OutputRow: View {
    let model: KodoModel
    let output: AudioDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.isSelected(output) }, set: { model.setSelected($0, for: output) })) {
                HStack {
                    Image(systemName: output.symbolName)
                        .frame(width: 18)
                    Text(output.name)
                        .lineLimit(1)
                    Spacer()
                    DelayBadge(model: model, output: output)
                }
            }
            .toggleStyle(.checkbox)

            if model.isSelected(output) {
                OutputControls(model: model, output: output)
                    .padding(.leading, 22)
            }
        }
    }
}

private struct DelayBadge: View {
    let model: KodoModel
    let output: AudioDevice

    var body: some View {
        if model.isSelected(output) {
            if let measurement = model.measurement(for: output), let delay = model.delay(for: output) {
                Text("+\(delay * 1000, format: .number.precision(.fractionLength(0))) ms")
                    .monospacedDigit()
                    .foregroundStyle(measurement.spread > 0.003 ? .orange : .secondary)
                    .help(help(for: measurement))
            } else {
                Text("Not calibrated")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func help(for measurement: Measurement) -> String {
        let latency = (measurement.latency * 1000).formatted(.number.precision(.fractionLength(1)))
        let spread = (measurement.spread * 1000).formatted(.number.precision(.fractionLength(1)))
        return "Measured \(latency) ms to the mic, runs within \(spread) ms. This output waits so the slowest one can catch up."
    }
}

private struct OutputControls: View {
    let model: KodoModel
    let output: AudioDevice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(get: { Double(model.volume(for: output)) }, set: { model.setVolume(Float($0), for: output) }),
                in: 0...1
            )
            .controlSize(.small)
            .accessibilityLabel("Volume for \(output.name)")

            NudgeControl(trim: model.trim(for: output)) { seconds in
                model.nudge(output, by: seconds)
            }
        }
        .font(.caption)
    }
}

/// Fine adjustment by ear, for when the mic sits somewhere other than your head.
private struct NudgeControl: View {
    let trim: Double
    let nudge: (Double) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button("Earlier", systemImage: "minus") { nudge(-0.002) }
            Text(label)
                .monospacedDigit()
                .frame(minWidth: 44)
            Button("Later", systemImage: "plus") { nudge(0.002) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Nudge this speaker 2 ms earlier or later")
    }

    private var label: String {
        let milliseconds = (trim * 1000).formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
        return "\(milliseconds) ms"
    }
}

private struct CalibrationSection: View {
    let model: KodoModel

    var body: some View {
        if let progress = model.calibration {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction) {
                    Text(progress.output.isEmpty ? "Getting ready…" : "Listening to \(progress.output)…")
                        .font(.callout)
                }
                Button("Cancel", action: model.cancelCalibration)
                    .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: model.calibrate) {
                    Label("Calibrate", systemImage: "waveform.badge.mic")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.activeOutputs.count < 2)

                Text(hint)
                    .font(.caption)
                    .foregroundStyle(model.needsCalibration ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hint: String {
        if model.activeOutputs.count < 2 {
            return "Pick two or more speakers to line them up."
        }
        if model.needsCalibration {
            return "Some speakers aren’t measured yet, so they may echo. Calibrate with the Mac where you usually listen."
        }
        return "Plays a short chirp through each speaker and listens with your Mac's microphone."
    }
}
