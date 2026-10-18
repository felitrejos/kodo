import SwiftUI

struct SpeakerRow: View {
    let model: KodoModel
    let output: AudioDevice

    var body: some View {
        let isSelected = model.isSelected(output)
        RowLayout(
            icon: .device(symbol: output.symbolName, isActive: isSelected && model.isOn),
            name: output.name,
            detail: detail,
            detailStyle: needsCalibration ? .orange : .secondary,
            isDimmed: !isSelected,
            toggle: SoundToggle(
                title: isSelected ? "Stop playing through \(output.name)" : "Play through \(output.name)",
                isOn: isSelected,
                level: Double(model.volume(for: output)),
                action: toggle)
        ) {
            LevelSlider(
                title: "Volume for \(output.name)",
                value: Double(model.volume(for: output)),
                isDimmed: !model.isOn,
                onChange: setVolume)
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
        }
        .contextMenu {
            Button("Nudge 2 ms Earlier", systemImage: "backward") { nudge(by: -0.002) }
            Button("Nudge 2 ms Later", systemImage: "forward") { nudge(by: 0.002) }
            Button("Reset Nudge", systemImage: "arrow.counterclockwise", action: resetTrim)
                .disabled(model.trim(for: output) == 0)
        }
    }

    private var needsCalibration: Bool {
        model.isSelected(output) && model.activeOutputs.count > 1 && model.measurement(for: output) == nil
    }

    private var detail: String {
        if needsCalibration {
            return "Not calibrated"
        }
        guard model.isSelected(output), let delay = model.delay(for: output), delay >= 0.0005 else {
            return output.kindDescription
        }
        let milliseconds = (delay * 1000).formatted(.number.precision(.fractionLength(0)))
        return "\(output.kindDescription) · waits \(milliseconds) ms"
    }

    private func toggle() {
        withAnimation(Design.animation) {
            model.toggle(output)
        }
    }

    private func setVolume(_ volume: Double) {
        model.setVolume(Float(volume), for: output)
    }

    private func nudge(by seconds: Double) {
        model.nudge(output, by: seconds)
    }

    private func resetTrim() {
        model.resetTrim(for: output)
    }
}
