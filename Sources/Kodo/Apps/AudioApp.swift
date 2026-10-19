import AppKit
import CoreAudio

/// An app that plays audio, with every helper process that plays on its behalf.
/// Browsers, for one, play each tab from a separate helper process.
struct AudioApp: Identifiable, Equatable {
    /// The bundle ID where there is one, so settings follow the app across launches.
    let id: String
    let name: String
    let bundleURL: URL?
    let processes: [AudioObjectID]
    let isPlaying: Bool

    var icon: NSImage {
        guard let bundleURL else {
            return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
}
