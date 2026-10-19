import Foundation

/// Keeps boosted audio from clipping harshly. Samples below the knee pass through untouched;
/// above it they bend smoothly towards full scale instead of being cut off flat.
public enum SoftClip {
    public static let knee: Float = 0.9

    @inline(__always)
    public static func apply(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > knee else {
            return sample
        }
        let headroom = 1 - knee
        let bent = knee + headroom * tanh((magnitude - knee) / headroom)
        return sample < 0 ? -bent : bent
    }
}
