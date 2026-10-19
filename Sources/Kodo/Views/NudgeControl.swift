import SwiftUI

/// Fine adjustment by ear, for when the microphone sits somewhere other than your head.
struct NudgeControl: View {
    let trim: Double
    let nudge: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button("Earlier", systemImage: "minus", action: earlier)
            Text(label)
                .monospacedDigit()
                .frame(minWidth: 44)
            Button("Later", systemImage: "plus", action: later)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Move this speaker 2 ms earlier or later")
    }

    private var label: String {
        let milliseconds = (trim * 1000).formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
        return "\(milliseconds) ms"
    }

    private func earlier() {
        nudge(-0.002)
    }

    private func later() {
        nudge(0.002)
    }
}
