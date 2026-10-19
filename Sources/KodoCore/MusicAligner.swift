import Accelerate

/// Finds where each speaker's copy of the music arrives in a microphone recording, without
/// a test signal.
///
/// Music correlates with itself over long stretches, so a plain cross-correlation gives
/// broad hills that blur speakers together. GCC-PHAT keeps only the phase of the cross
/// spectrum, which turns every arrival into a sharp spike.
public enum MusicAligner {
    /// Spikes this much weaker than the strongest are treated as noise or reflections.
    public static let relativeThreshold: Float = 0.35

    /// Arrival offsets of `reference` within `recording`, in frames, strongest first.
    /// - Parameters:
    ///   - maximumLag: How far into the recording to look.
    ///   - separation: Spikes closer than this count as one.
    public static func arrivals(of reference: [Float], in recording: [Float], maximumLag: Int, separation: Int) -> [Int] {
        guard !reference.isEmpty, recording.count > reference.count else {
            return []
        }
        let correlation = phaseCorrelation(reference, recording)
        let searchCount = min(maximumLag, correlation.count - 1)
        guard searchCount > 2 else {
            return []
        }

        var peaks: [(lag: Int, value: Float)] = []
        for lag in 1..<searchCount where correlation[lag] > correlation[lag - 1] && correlation[lag] >= correlation[lag + 1] {
            peaks.append((lag, correlation[lag]))
        }
        peaks.sort { $0.value > $1.value }
        guard let strongest = peaks.first?.value, strongest > 0 else {
            return []
        }

        var kept: [Int] = []
        for peak in peaks where peak.value >= strongest * relativeThreshold {
            if kept.allSatisfy({ abs($0 - peak.lag) >= separation }) {
                kept.append(peak.lag)
            }
        }
        return kept
    }

    /// `result[k]` peaks where `reference` appears `k` frames into `recording`.
    static func phaseCorrelation(_ reference: [Float], _ recording: [Float]) -> [Float] {
        var length = 1
        while length < recording.count + reference.count {
            length <<= 1
        }
        guard
            let forward = try? vDSP.DiscreteFourierTransform(count: length, direction: .forward, transformType: .complexComplex, ofType: Float.self),
            let inverse = try? vDSP.DiscreteFourierTransform(count: length, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else {
            return []
        }

        let zeros = [Float](repeating: 0, count: length)
        var recordingReal = [Float](repeating: 0, count: length)
        var recordingImaginary = [Float](repeating: 0, count: length)
        forward.transform(inputReal: recording + [Float](repeating: 0, count: length - recording.count), inputImaginary: zeros, outputReal: &recordingReal, outputImaginary: &recordingImaginary)
        var referenceReal = [Float](repeating: 0, count: length)
        var referenceImaginary = [Float](repeating: 0, count: length)
        forward.transform(inputReal: reference + [Float](repeating: 0, count: length - reference.count), inputImaginary: zeros, outputReal: &referenceReal, outputImaginary: &referenceImaginary)

        // recording × conj(reference), normalized to unit magnitude.
        var productReal = [Float](repeating: 0, count: length)
        var productImaginary = [Float](repeating: 0, count: length)
        for index in 0..<length {
            let (a, b) = (recordingReal[index], recordingImaginary[index])
            let (c, d) = (referenceReal[index], referenceImaginary[index])
            let real = a * c + b * d
            let imaginary = b * c - a * d
            let magnitude = (real * real + imaginary * imaginary).squareRoot() + 1e-9
            productReal[index] = real / magnitude
            productImaginary[index] = imaginary / magnitude
        }

        var resultReal = [Float](repeating: 0, count: length)
        var resultImaginary = [Float](repeating: 0, count: length)
        inverse.transform(inputReal: productReal, inputImaginary: productImaginary, outputReal: &resultReal, outputImaginary: &resultImaginary)
        return Array(resultReal.prefix(recording.count))
    }

    /// Linear resampling, enough for correlating music recorded at another rate.
    public static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard sourceRate != targetRate, sourceRate > 0, samples.count > 1 else {
            return samples
        }
        let ratio = sourceRate / targetRate
        let count = Int(Double(samples.count - 1) / ratio)
        return (0..<count).map { index in
            let position = Double(index) * ratio
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            return samples[lower] * (1 - fraction) + samples[min(lower + 1, samples.count - 1)] * fraction
        }
    }
}
