import Accelerate

/// Where a known signal shows up inside a recording.
public struct Arrival: Equatable, Sendable {
    /// Offset into the recording, in frames, where the signal starts.
    public var frame: Int
    /// Normalized correlation at the peak, from 0 (nothing like the signal) to 1 (an exact copy).
    public var strength: Float
}

/// Finds a reference signal in a recording with an FFT cross-correlation (a matched filter).
public enum ArrivalDetector {
    /// Below this the peak is more likely noise than the chirp.
    public static let minimumStrength: Float = 0.08

    public static func locate(_ reference: [Float], in recording: [Float]) -> Arrival? {
        guard !reference.isEmpty, recording.count >= reference.count else {
            return nil
        }

        let correlation = crossCorrelate(reference, recording)
        let searchCount = recording.count - reference.count + 1

        var bestFrame = 0
        var bestValue: Float = 0
        for frame in 0..<searchCount where abs(correlation[frame]) > bestValue {
            bestValue = abs(correlation[frame])
            bestFrame = frame
        }

        let referenceEnergy = vDSP.sumOfSquares(reference)
        let windowEnergy = recording.withUnsafeBufferPointer { samples in
            vDSP.sumOfSquares(UnsafeBufferPointer(rebasing: samples[bestFrame..<bestFrame + reference.count]))
        }
        guard referenceEnergy > 0, windowEnergy > 0 else {
            return nil
        }

        let strength = bestValue / (referenceEnergy * windowEnergy).squareRoot()
        return Arrival(frame: bestFrame, strength: min(strength, 1))
    }

    /// `result[k]` is the dot product of `reference` with `recording` shifted left by `k`.
    static func crossCorrelate(_ reference: [Float], _ recording: [Float]) -> [Float] {
        var length = 1
        while length < recording.count + reference.count {
            length <<= 1
        }

        guard
            let forward = try? vDSP.DiscreteFourierTransform(
                count: length, direction: .forward, transformType: .complexComplex, ofType: Float.self),
            let inverse = try? vDSP.DiscreteFourierTransform(
                count: length, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else {
            return []
        }

        let zeros = [Float](repeating: 0, count: length)
        let recordingSpectrum = run(forward, real: padded(recording, to: length), imaginary: zeros)
        let referenceSpectrum = run(forward, real: padded(reference, to: length), imaginary: zeros)

        // recording × conj(reference)
        var productReal = [Float](repeating: 0, count: length)
        var productImaginary = [Float](repeating: 0, count: length)
        for index in 0..<length {
            let (a, b) = (recordingSpectrum.real[index], recordingSpectrum.imaginary[index])
            let (c, d) = (referenceSpectrum.real[index], referenceSpectrum.imaginary[index])
            productReal[index] = a * c + b * d
            productImaginary[index] = b * c - a * d
        }

        let result = run(inverse, real: productReal, imaginary: productImaginary)
        return vDSP.divide(Array(result.real.prefix(recording.count)), Float(length))
    }

    private static func run(
        _ transform: vDSP.DiscreteFourierTransform<Float>, real: [Float], imaginary: [Float]
    ) -> (real: [Float], imaginary: [Float]) {
        var outputReal = [Float](repeating: 0, count: real.count)
        var outputImaginary = [Float](repeating: 0, count: real.count)
        transform.transform(
            inputReal: real, inputImaginary: imaginary,
            outputReal: &outputReal, outputImaginary: &outputImaginary)
        return (outputReal, outputImaginary)
    }

    private static func padded(_ samples: [Float], to length: Int) -> [Float] {
        samples + [Float](repeating: 0, count: length - samples.count)
    }
}
