import Foundation

/// What Kodo remembers between launches, keyed by device UID so it survives reconnects.
struct KodoSettings: Codable, Equatable {
    var selectedOutputs: Set<String> = []
    var measurements: [String: Measurement] = [:]
    /// Manual nudges on top of the measurement, in seconds.
    var trims: [String: Double] = [:]
    var volumes: [String: Float] = [:]

    private static let key = "settings"

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
