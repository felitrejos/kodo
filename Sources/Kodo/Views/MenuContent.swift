import SwiftUI

struct MenuContent: View {
    let model: KodoModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.cardSpacing) {
            HeaderView(model: model)
            GlassEffectContainer(spacing: Design.cardSpacing) {
                VStack(spacing: Design.cardSpacing) {
                    if let offer = model.soundMenuOffer {
                        SoundMenuOfferCard(model: model, offer: offer)
                    }
                    SpeakersCard(model: model)
                    AppsCard(model: model)
                }
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(Design.outerPadding)
        .frame(width: Design.menuWidth)
        .animation(Design.animation, value: model.isSyncOn)
        .onAppear { model.setMenuOpen(true) }
        .onDisappear { model.setMenuOpen(false) }
    }
}

#Preview("Sync on") {
    MenuContent(model: PreviewData.model())
}

#Preview("Sound menu offer") {
    MenuContent(model: PreviewData.model(kodoOutputStatus: .notInstalled))
}

#Preview("Sync off") {
    MenuContent(model: PreviewData.model(isSyncOn: false))
}
