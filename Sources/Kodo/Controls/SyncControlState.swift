import Foundation

/// What the Speaker Sync control in Control Center shows. Kodo writes it to its own
/// preferences, which the control is allowed to read, and the control asks Kodo to switch
/// Sync with a `kodo://` link, which also opens Kodo if it isn't running.
///
/// Built into both Kodo and its Controls extension.
struct SyncControlState: Equatable, Sendable {
    static let kind = "com.felipetrejos.kodo.speaker-sync"
    private static let domain = "com.felipetrejos.kodo"
    private static let isOnKey = "controlSyncOn"
    private static let groupKey = "controlGroupName"

    var isOn: Bool
    var groupName: String

    static func read() -> SyncControlState {
        let defaults = UserDefaults(suiteName: domain)
        return SyncControlState(
            isOn: defaults?.bool(forKey: isOnKey) ?? false,
            groupName: defaults?.string(forKey: groupKey) ?? "Speaker Sync")
    }

    func write() {
        UserDefaults.standard.set(isOn, forKey: Self.isOnKey)
        UserDefaults.standard.set(groupName, forKey: Self.groupKey)
    }

    static func link(turningOn on: Bool) -> URL {
        URL(string: "kodo://sync/\(on ? "on" : "off")")!
    }

    /// The Sync setting a link asks for, if it's one of these.
    static func requestedSync(in url: URL) -> Bool? {
        guard url.scheme == "kodo", url.host() == "sync" else {
            return nil
        }
        return switch url.lastPathComponent {
        case "on": true
        case "off": false
        default: nil
        }
    }
}
