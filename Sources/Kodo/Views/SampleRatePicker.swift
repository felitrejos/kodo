import SwiftUI

struct SampleRatePicker: View {
    let details: DeviceDetails
    let choose: (Double) -> Void

    var body: some View {
        if details.availableSampleRates.count > 1 {
            Menu(Self.describe(details.sampleRate)) {
                ForEach(details.availableSampleRates, id: \.self) { rate in
                    Button(Self.describe(rate)) {
                        choose(rate)
                    }
                    .disabled(rate == details.sampleRate)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        } else {
            Text(Self.describe(details.sampleRate))
                .monospacedDigit()
        }
    }

    static func describe(_ rate: Double) -> String {
        "\((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }
}
