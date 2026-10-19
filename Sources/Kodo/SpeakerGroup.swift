import Foundation

/// A saved set of speakers that play together, like "Living room" or "Desk".
///
/// Fine-tune results belong to the group, not the speaker: the aggregate pads each member
/// to the slowest one, so the same speaker measures differently next to different company.
struct SpeakerGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Device UIDs, which survive reconnects and reboots.
    var outputs: Set<String> = []
    var volumes: [String: Float] = [:]
    /// Speakers muted within the group. They stay in it, so unmuting is instant.
    var mutedOutputs: Set<String> = []
    var measurements: [String: Measurement] = [:]
    /// Manual nudges by ear, in seconds.
    var trims: [String: Double] = [:]
    /// Corrections Keep in Sync found by listening to the music, in seconds.
    var drifts: [String: Double] = [:]
    var calibratedAt: Date?
    /// The speaker you chose to lead, whose clock the others follow. Nil lets Kodo choose.
    var leadUID: String?
    /// The lead when the measurements were taken. Resampling adds a little delay to every
    /// speaker but the lead, so measurements only hold for the lead they were taken with.
    var measuredLeadUID: String?

    init(name: String) {
        self.name = name
    }

    /// Fields added later are missing from older saves; default them instead of losing the rest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Speakers"
        outputs = try container.decodeIfPresent(Set<String>.self, forKey: .outputs) ?? []
        volumes = try container.decodeIfPresent([String: Float].self, forKey: .volumes) ?? [:]
        mutedOutputs = try container.decodeIfPresent(Set<String>.self, forKey: .mutedOutputs) ?? []
        measurements = try container.decodeIfPresent([String: Measurement].self, forKey: .measurements) ?? [:]
        trims = try container.decodeIfPresent([String: Double].self, forKey: .trims) ?? [:]
        drifts = try container.decodeIfPresent([String: Double].self, forKey: .drifts) ?? [:]
        calibratedAt = try container.decodeIfPresent(Date.self, forKey: .calibratedAt)
        leadUID = try container.decodeIfPresent(String.self, forKey: .leadUID)
        // Fine-tunes from before leads existed always had the built-in speakers as the clock.
        measuredLeadUID = try container.decodeIfPresent(String.self, forKey: .measuredLeadUID)
            ?? (measurements["BuiltInSpeakerDevice"] != nil ? "BuiltInSpeakerDevice" : nil)
    }
}
