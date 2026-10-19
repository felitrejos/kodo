import Foundation

/// What Kodo remembers between launches, keyed by device UID and bundle ID so it survives
/// reconnects and relaunches.
struct KodoSettings: Codable, Equatable {
    /// Always at least one; the menu shows the active one.
    var groups = [SpeakerGroup(name: "My Speakers")]
    var activeGroupID: UUID
    /// Whether you turned Speaker Sync on. It stays on while the group's speakers are away,
    /// so they pick up where they left off when they reconnect.
    var syncEnabled = false
    /// Speakers you hid from the menu.
    var hiddenOutputs: Set<String> = []

    /// Per-app volume and mute, keyed by bundle ID. Muted apps keep their volume for later.
    var appVolumes: [String: Float] = [:]
    var mutedApps: Set<String> = []
    /// Apps sent to one speaker instead of wherever Kodo plays: bundle ID to device UID.
    var appRoutes: [String: String] = [:]
    /// Apps whose slider goes up to 200%.
    var boostedApps: Set<String> = []

    /// Whether Kodo may listen to the music now and then to keep a group in step.
    var keepsInSync = false

    private static let key = "settings"

    init() {
        activeGroupID = groups[0].id
    }

    private enum CodingKeys: String, CodingKey {
        case groups, activeGroupID, syncEnabled, hiddenOutputs
        case appVolumes, mutedApps, appRoutes, boostedApps, keepsInSync
        // From before groups existed, read once to build the first group.
        case selectedOutputs, volumes, mutedOutputs, measurements, trims, calibratedAt
    }

    /// Fields added later are missing from older saves; default them instead of losing the rest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let groups = try container.decodeIfPresent([SpeakerGroup].self, forKey: .groups), !groups.isEmpty {
            self.groups = groups
        } else {
            var group = SpeakerGroup(name: "My Speakers")
            group.outputs = try container.decodeIfPresent(Set<String>.self, forKey: .selectedOutputs) ?? []
            group.volumes = try container.decodeIfPresent([String: Float].self, forKey: .volumes) ?? [:]
            group.mutedOutputs = try container.decodeIfPresent(Set<String>.self, forKey: .mutedOutputs) ?? []
            group.measurements = try container.decodeIfPresent([String: Measurement].self, forKey: .measurements) ?? [:]
            group.trims = try container.decodeIfPresent([String: Double].self, forKey: .trims) ?? [:]
            group.calibratedAt = try container.decodeIfPresent(Date.self, forKey: .calibratedAt)
            groups = [group]
        }
        let activeID = try container.decodeIfPresent(UUID.self, forKey: .activeGroupID)
        activeGroupID = groups.contains { $0.id == activeID } ? activeID ?? groups[0].id : groups[0].id
        syncEnabled = try container.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        hiddenOutputs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenOutputs) ?? []
        appVolumes = try container.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:]
        mutedApps = try container.decodeIfPresent(Set<String>.self, forKey: .mutedApps) ?? []
        appRoutes = try container.decodeIfPresent([String: String].self, forKey: .appRoutes) ?? [:]
        boostedApps = try container.decodeIfPresent(Set<String>.self, forKey: .boostedApps) ?? []
        keepsInSync = try container.decodeIfPresent(Bool.self, forKey: .keepsInSync) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groups, forKey: .groups)
        try container.encode(activeGroupID, forKey: .activeGroupID)
        try container.encode(syncEnabled, forKey: .syncEnabled)
        try container.encode(hiddenOutputs, forKey: .hiddenOutputs)
        try container.encode(appVolumes, forKey: .appVolumes)
        try container.encode(mutedApps, forKey: .mutedApps)
        try container.encode(appRoutes, forKey: .appRoutes)
        try container.encode(boostedApps, forKey: .boostedApps)
        try container.encode(keepsInSync, forKey: .keepsInSync)
    }

    /// The group the menu shows and Sync plays.
    var activeGroup: SpeakerGroup {
        get {
            groups.first { $0.id == activeGroupID } ?? groups[0]
        }
        set {
            guard let index = groups.firstIndex(where: { $0.id == activeGroupID }) else {
                groups[0] = newValue
                return
            }
            groups[index] = newValue
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> KodoSettings {
        guard
            let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(KodoSettings.self, from: data)
        else {
            return KodoSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
