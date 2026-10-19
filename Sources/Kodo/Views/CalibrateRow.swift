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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Fine-tune", systemImage: "waveform.badge.mic", action: calibrate)
                    .controlSize(.small)
                    .buttonStyle(.glass)
                    .disabled(model.activeOutputs.count < 2)
                    .help("Times each speaker with a short chirp and your Mac's microphone, for an exact match")
            }
        }
    }

    private var note: String {
        if model.activeOutputs.count < 2 {
            return "Add another speaker to sync"
        }
        // Sync already works from what each speaker reports about itself; measuring is the
        // optional step from close to exact.
        if model.needsCalibration {
            return "Approximate sync"
        }
        guard let date = model.settings.calibratedAt else {
            return "Fine-tuned"
        }
        return "Fine-tuned \(date.formatted(.relative(presentation: .named)))"
    }

    private func calibrate() {
        model.calibrate()
    }

    private func cancel() {
        model.cancelCalibration()
    }
}
