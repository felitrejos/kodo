import SwiftUI

/// The one-time offer to add Kodo to the Sound list, or to update it.
struct SoundMenuOfferCard: View {
    let model: KodoModel
    let offer: KodoModel.SoundMenuOffer

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: MenuBarIcon.image(.filled))
                    .renderingMode(.template)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                if model.isInstallingKodoOutput {
                    Text("Waiting for your password…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Not Now") { model.declineSoundMenuOffer() }
                    Button(offer == .add ? "Add" : "Update") { model.installKodoOutput() }
                        .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.small)
        }
    }

    private var title: String {
        offer == .add ? "Add Kodo to your Sound menu?" : "Update Kodo in your Sound menu"
    }

    private var message: String {
        switch offer {
        case .add:
            "Pick Kodo in Control Center to play this group, and its slider turns every speaker up and down. Asks for your password once."
        case .update:
            "This version of Kodo comes with a newer Sound menu driver. Asks for your password once."
        }
    }
}
