import SwiftUI

/// Where an app plays: wherever Kodo plays, or one particular speaker.
struct RouteMenu: View {
    let model: KodoModel
    let app: AudioApp

    var body: some View {
        Picker("Play \(app.name) Through", selection: Binding(get: { model.route(for: app)?.uid }, set: { choose($0) })) {
            Text(model.isSyncOn ? "Speaker Sync" : "Mac Output")
                .tag(String?.none)
            Divider()
            ForEach(model.routableOutputs) { output in
                Label(output.name, systemImage: output.symbolName)
                    .tag(Optional(output.uid))
            }
        }
        .pickerStyle(.inline)
    }

    private func choose(_ uid: String?) {
        model.setRoute(model.routableOutputs.first { $0.uid == uid }, for: app)
    }
}
