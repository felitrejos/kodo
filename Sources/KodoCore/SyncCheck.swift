/// Works out which speaker is early or late from music arrivals, by shifting one speaker at
/// a time and seeing which arrival moves.
///
/// With every speaker playing the same music, the microphone hears one arrival per speaker
/// but can't tell them apart; when they're aligned they even overlap. Delaying speaker `k` by
/// a known shift makes exactly one arrival move by that shift, and that one is `k`.
public enum SyncCheck {
    /// Arrival times that are this close are already in step.
    public static let tolerance = 0.001
    /// Anything bigger is a moved speaker or a bad listen, which is Fine-tune's job.
    public static let largestCorrection = 0.03

    /// Each speaker's arrival time, or nil when the listens don't tell a clear story.
    /// - Parameters:
    ///   - baseline: Arrivals with every speaker at its normal delay, in seconds.
    ///   - shifted: For each speaker, the arrivals while only it was delayed by `shift`.
    public static func arrivals<Key: Hashable>(baseline: [Double], shifted: [Key: [Double]], shift: Double) -> [Key: Double]? {
        var arrivals: [Key: Double] = [:]
        for (speaker, listen) in shifted {
            // The arrival that is new compared with the baseline, and one shift later than a
            // baseline arrival, belongs to the shifted speaker.
            let moved = listen.filter { arrival in
                !baseline.contains { abs($0 - arrival) < tolerance }
                    && baseline.contains { abs($0 + shift - arrival) < tolerance }
            }
            guard moved.count == 1, let arrival = moved.first else {
                return nil
            }
            arrivals[speaker] = baseline.min { abs($0 + shift - arrival) < abs($1 + shift - arrival) }
        }
        return arrivals
    }

    /// Extra delay for each speaker so they all arrive with the latest one, or nil when they're
    /// already in step or the correction is too big to trust.
    public static func corrections<Key: Hashable>(for arrivals: [Key: Double]) -> [Key: Double]? {
        guard let latest = arrivals.values.max(), let earliest = arrivals.values.min() else {
            return nil
        }
        let spread = latest - earliest
        guard spread >= tolerance, spread <= largestCorrection else {
            return nil
        }
        return arrivals.mapValues { latest - $0 }
    }
}
