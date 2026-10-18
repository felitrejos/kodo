import SwiftUI

struct CalibrateRow: View {
    let model: KodoModel

    var body: some View {
        HStack(spacing: 8) {
            if let progress = model.calibration {
                ProgressView(value: progress.fraction)
                    .controlSize(.small)
                    .frame(width: 60)
                Text(progress.output.isEmpty ? "Getting ready…" : "Listening to \(progress.output)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", action: cancel)
                    .controlSize(.small)
            } else {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(model.needsCalibration ? .orange : .secondary)
                    .lineLimit(1)
                Spacer()
                Button("Calibrate", systemImage: "waveform.badge.mic", action: calibrate)
                    .controlSize(.small)
                    .buttonStyle(.glass)
                    .disabled(model.activeOutputs.count < 2)
                    .help("Plays a short chirp through each speaker and times it with your Mac's microphone")
            }
        }
    }

    private var note: String {
        if model.activeOutputs.count < 2 {
            return "Add another speaker to sync"
        }
        if model.needsCalibration {
            return "Calibrate to line up new speakers"
        }
        guard let date = model.settings.calibratedAt else {
            return "Calibrated"
        }
        return "Calibrated \(date.formatted(.relative(presentation: .named)))"
    }

    private func calibrate() {
        model.calibrate()
    }

    private func cancel() {
        model.cancelCalibration()
    }
}
