import Foundation

/// The calibration signal: a logarithmic sine sweep.
///
/// A sweep spreads its energy across the band, so its autocorrelation is a single sharp
/// spike. That makes the arrival time easy to pick out of a noisy, reverberant room.
public enum Chirp {
    public static let lowFrequency = 200.0
    public static let highFrequency = 8_000.0
    public static let duration = 0.4
    public static let amplitude: Float = 0.3

    public static func sweep(
        sampleRate: Double,
        from lowFrequency: Double = lowFrequency,
        to highFrequency: Double = highFrequency,
        duration: Double = duration,
        amplitude: Float = amplitude
    ) -> [Float] {
        let frameCount = Int(duration * sampleRate)
        let sweepRate = log(highFrequency / lowFrequency)
        // Short raised-cosine fades keep the edges from clicking, which would smear the peak.
        let fadeFrames = min(Int(0.01 * sampleRate), frameCount / 2)

        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let phase = 2 * Double.pi * lowFrequency * duration / sweepRate
                * (exp(time / duration * sweepRate) - 1)
            var envelope = 1.0
            if frame < fadeFrames {
                envelope = 0.5 - 0.5 * cos(Double.pi * Double(frame) / Double(fadeFrames))
            } else if frame >= frameCount - fadeFrames {
                envelope = 0.5 - 0.5 * cos(Double.pi * Double(frameCount - 1 - frame) / Double(fadeFrames))
            }
            return amplitude * Float(envelope * sin(phase))
        }
    }
}
