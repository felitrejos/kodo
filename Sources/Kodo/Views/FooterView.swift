import SwiftUI

struct FooterView: View {
    let model: KodoModel

    var body: some View {
        HStack(spacing: 8) {
            if let progress = model.calibration {
                ProgressView(value: progress.fraction)
                    .controlSize(.small)
                Text(progress.output.isEmpty ? "Getting ready…" : "Listening to \(progress.output)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", action: cancel)
                    .controlSize(.small)
            } else {
                Button("Calibrate", systemImage: "waveform.badge.mic", action: calibrate)
                    .controlSize(.small)
                    .disabled(model.activeOutputs.count < 2)
                    .help("Plays a short chirp through each speaker and times it with your Mac's microphone")
                Text(calibrationNote)
                    .font(.caption)
                    .foregroundStyle(model.needsCalibration ? .orange : .secondary)
                    .lineLimit(1)
                Spacer()
                MoreMenu(model: model)
            }
        }
    }

    private var calibrationNote: String {
        if model.activeOutputs.count < 2 {
            return "Add a second speaker to sync"
        }
        if model.needsCalibration {
            return "New speaker, calibrate to sync"
        }
        guard let date = model.settings.calibratedAt else {
            return ""
        }
        return "Synced \(date.formatted(.relative(presentation: .named)))"
    }

    private func calibrate() {
        model.calibrate()
    }

    private func cancel() {
        model.cancelCalibration()
    }
}
