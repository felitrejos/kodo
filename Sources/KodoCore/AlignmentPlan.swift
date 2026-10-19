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

    /// The value most runs agree on, or nil when too few agree to trust any of them.
    ///
    /// A Bluetooth speaker far from the microphone can land a run somewhere else entirely,
    /// and a median of disagreeing runs is still wrong. So this looks for the biggest set of
    /// runs within `tolerance` of each other and takes their median, but only if at least
    /// `minimumAgreeing` of them agree.
    public static func consensus(_ runs: [Double], tolerance: Double, minimumAgreeing: Int) -> (value: Double, spread: Double)? {
        let sorted = runs.sorted()
        var best: ArraySlice<Double> = []
        var start = 0
        for end in sorted.indices {
            while sorted[end] - sorted[start] > tolerance {
                start += 1
            }
            if end - start + 1 > best.count {
                best = sorted[start...end]
            }
        }
        guard best.count >= minimumAgreeing, let value = combine(Array(best)) else {
            return nil
        }
        return (value, spread(Array(best)))
    }

    /// How far apart the runs were, so the UI can flag a shaky calibration.
    public static func spread(_ measurements: [Double]) -> Double {
        guard let low = measurements.min(), let high = measurements.max() else {
            return 0
        }
        return high - low
    }
}
