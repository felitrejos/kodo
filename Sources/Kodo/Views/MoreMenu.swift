import SwiftUI

struct MoreMenu: View {
    let model: KodoModel

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Toggle("Keep in Sync Automatically", isOn: Binding(get: { model.settings.keepsInSync }, set: { model.setKeepsInSync($0) }))
                .help("Every 10 minutes while music plays, listens with the microphone for a few seconds and corrects any drift")
            Toggle("Open at Login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchesAtLogin($0) }))
            soundOutputItem
            Divider()
            Button("Quit Kodo", action: quit)
                .keyboardShortcut("q")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Adding and updating are offered once, in the menu itself. This is the way back to
    /// either choice: removing while Kodo is in the Sound list, adding once you've said Not Now.
    /// Both ask for your password, then Kodo restarts.
    @ViewBuilder private var soundOutputItem: some View {
        switch model.kodoOutputStatus {
        case .installed, .outdated:
            Button("Remove Kodo from Sound Menu…") { model.removeKodoOutput() }
                .disabled(model.isInstallingKodoOutput)
        case .notInstalled where model.settings.declinedSoundMenu:
            Button("Add Kodo to Sound Menu…") { model.installKodoOutput() }
                .disabled(model.isInstallingKodoOutput)
        case .notInstalled, .unavailable:
            EmptyView()
        }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
