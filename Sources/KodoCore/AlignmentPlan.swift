/// Turns measured latencies into the delay each output needs so they all arrive together.
public enum AlignmentPlan {
    /// The fastest outputs wait for the slowest one. A trim nudges an output by ear on top of
    /// the measurement; if a trim would ask for a negative delay, everything shifts later instead.
    ///
    /// - Parameters:
    ///   - latencies: Measured output latency per output, in seconds.
    ///   - trims: Extra delay per output, in seconds. Missing keys count as zero.
    /// - Returns: The delay to apply per output, in seconds, never negative.
    public static func delays<Key: Hashable>(
        latencies: [Key: Double],
        trims: [Key: Double] = [:]
    ) -> [Key: Double] {
        guard let slowest = latencies.values.max() else {
            return [:]
        }

        let raw = latencies.mapValues { slowest - $0 }
            .merging(trims.filter { latencies.keys.contains($0.key) }) { $0 + $1 }
        let earliest = min(raw.values.min() ?? 0, 0)
        return raw.mapValues { $0 - earliest }
    }

    /// Combines repeated measurements of one output. The median shrugs off the odd run where a
    /// reflection or a noise burst won the correlation.
    public static func combine(_ measurements: [Double]) -> Double? {
        guard !measurements.isEmpty else {
            return nil
        }

        let sorted = measurements.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// How far apart the runs were, so the UI can flag a shaky calibration.
    public static func spread(_ measurements: [Double]) -> Double {
        guard let low = measurements.min(), let high = measurements.max() else {
            return 0
        }
        return high - low
    }
}
