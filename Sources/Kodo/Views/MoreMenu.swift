import SwiftUI

struct MoreMenu: View {
    let model: KodoModel

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Toggle("Keep in Sync Automatically", isOn: Binding(get: { model.settings.keepsInSync }, set: { model.setKeepsInSync($0) }))
                .help("Every 10 minutes while music plays, listens with the microphone for a few seconds and corrects any drift")
            Toggle("Open at Login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchesAtLogin($0) }))
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

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
