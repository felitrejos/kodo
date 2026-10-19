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

    /// Adding, updating, or removing Kodo in the Sound output list. Each asks for your password,
    /// then Kodo restarts.
    @ViewBuilder private var soundOutputItem: some View {
        switch model.kodoOutputStatus {
        case .unavailable:
            EmptyView()
        case .notInstalled:
            Button("Add Kodo to Sound Output…") { model.installKodoOutput() }
                .help("Lists Kodo next to your speakers in Control Center and Sound settings. Picking it turns Speaker Sync on.")
                .disabled(model.isInstallingKodoOutput)
        case .outdated:
            Button("Update Kodo in Sound Output…") { model.installKodoOutput() }
                .disabled(model.isInstallingKodoOutput)
        case .installed:
            Button("Remove Kodo from Sound Output…") { model.removeKodoOutput() }
                .disabled(model.isInstallingKodoOutput)
        }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
