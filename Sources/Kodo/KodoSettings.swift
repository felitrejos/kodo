import Foundation

/// What Kodo remembers between launches, keyed by device UID so it survives reconnects.
struct KodoSettings: Codable, Equatable {
    var selectedOutputs: Set<String> = []
    var measurements: [String: Measurement] = [:]
    /// Manual nudges on top of the measurement, in seconds.
    var trims: [String: Double] = [:]
    var volumes: [String: Float] = [:]
    /// Muted outputs keep their volume, so unmuting brings back the old level.
    var mutedOutputs: Set<String> = []

    private static let key = "settings"

    init() {}

    /// Fields added later are missing from older saves; default them instead of losing the rest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedOutputs = try container.decodeIfPresent(Set<String>.self, forKey: .selectedOutputs) ?? []
        measurements = try container.decodeIfPresent([String: Measurement].self, forKey: .measurements) ?? [:]
        trims = try container.decodeIfPresent([String: Double].self, forKey: .trims) ?? [:]
        volumes = try container.decodeIfPresent([String: Float].self, forKey: .volumes) ?? [:]
        mutedOutputs = try container.decodeIfPresent(Set<String>.self, forKey: .mutedOutputs) ?? []
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
