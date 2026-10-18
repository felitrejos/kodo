import Foundation

/// The alignment test signal: a few sharp clicks with silence between them.
///
/// Music hides small offsets; a click doesn't. Two speakers 10 ms apart turn one click into
/// an audible double tap, so you can judge the alignment from your seat.
public enum ClickTrain {
    public static let clickCount = 8
    public static let interval = 0.5
    public static let amplitude: Float = 0.6

    /// Clicks start at frame zero; the last one is followed by `interval` of silence.
    public static func samples(sampleRate: Double) -> [Float] {
        let intervalFrames = Int(interval * sampleRate)
        var samples = [Float](repeating: 0, count: clickCount * intervalFrames)
        let click = self.click(sampleRate: sampleRate)
        for index in 0..<clickCount {
            let start = index * intervalFrames
            samples.replaceSubrange(start..<start + click.count, with: click)
        }
        return samples
    }

    /// A fast-decaying 2.5 kHz burst, a few milliseconds long: short enough to sound like a
    /// tick, with enough body that small Bluetooth speakers still reproduce it.
    static func click(sampleRate: Double) -> [Float] {
        let frameCount = Int(0.004 * sampleRate)
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            return amplitude * Float(exp(-time / 0.0007) * sin(2 * Double.pi * 2_500 * time))
        }
    }
}
