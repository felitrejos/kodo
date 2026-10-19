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

    /// Loaded once per app: asking the workspace builds a fresh image every time, and a row
    /// that redraws would load it from disk again.
    @MainActor var icon: NSImage {
        guard let bundleURL else {
            return Self.placeholderIcon
        }
        if let icon = Self.icons[bundleURL] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        Self.icons[bundleURL] = icon
        return icon
    }

    @MainActor private static var icons: [URL: NSImage] = [:]
    @MainActor private static let placeholderIcon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
}
