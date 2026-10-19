import AppIntents
import AppKit
import SwiftUI
import WidgetKit

@main
struct KodoControls: WidgetBundle {
    var body: some Widget {
        SpeakerSyncControl()
    }
}

/// Speaker Sync as a control you add to Control Center or the menu bar from Edit Controls.
struct SpeakerSyncControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SyncControlState.kind, provider: Provider()) { state in
            ControlWidgetToggle("Speaker Sync", isOn: state.isOn, action: SetSpeakerSync()) { isOn in
                Label(isOn ? state.groupName : "Off", image: "taiko")
            }
        }
        .displayName("Speaker Sync")
        .description("Play your Mac through every speaker in your Kodo group.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: SyncControlState {
            SyncControlState(isOn: false, groupName: "Speaker Sync")
        }

        func currentValue() async throws -> SyncControlState {
            SyncControlState.read()
        }
    }
}

struct SetSpeakerSync: SetValueIntent {
    static let title: LocalizedStringResource = "Set Speaker Sync"

    @Parameter(title: "Speaker Sync")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let configuration = NSWorkspace.OpenConfiguration()
        // Kodo lives in the menu bar; there's nothing to bring forward.
        configuration.activates = false
        _ = try await NSWorkspace.shared.open(SyncControlState.link(turningOn: value), configuration: configuration)
        return .result()
    }
}
