import Foundation

/// Recent dropouts per speaker, to tell a one-off glitch from a speaker that keeps cutting out.
///
/// One glitch, or switching a speaker off on purpose, isn't worth a warning. Several within a
/// few minutes usually means a weak connection: too far from the Mac, or something in the way.
public struct DropoutLog<Key: Hashable>: Sendable where Key: Sendable {
    /// How far back a dropout still counts.
    public let window: TimeInterval
    /// How many dropouts within the window make a speaker one that's cutting out.
    public let threshold: Int
    /// Glitches closer together than this are one dropout: a stall shows up as a burst.
    public let burst: TimeInterval
    private var events: [Key: [Date]] = [:]

    public init(window: TimeInterval = 600, threshold: Int = 3, burst: TimeInterval = 5) {
        self.window = window
        self.threshold = threshold
        self.burst = burst
    }

    public mutating func record(_ key: Key, at date: Date) {
        var dates = events[key, default: []]
        if let last = dates.last, date.timeIntervalSince(last) < burst {
            return
        }
        dates.append(date)
        events[key] = dates
    }

    /// Dropouts within the window.
    public func count(for key: Key, at now: Date) -> Int {
        events[key, default: []].count { now.timeIntervalSince($0) <= window }
    }

    /// Speakers with at least `threshold` dropouts in the window. Forgets older ones.
    public mutating func cuttingOut(at now: Date) -> Set<Key> {
        events = events.compactMapValues { dates in
            let recent = dates.filter { now.timeIntervalSince($0) <= window }
            return recent.isEmpty ? nil : recent
        }
        return Set(events.filter { $0.value.count >= threshold }.keys)
    }
}
