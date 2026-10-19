/// A stereo history of the captured audio that every output reads from at its own delay.
///
/// It is used from the audio thread, so it never allocates or locks after `init`.
public final class DelayLine: @unchecked Sendable {
    public static let channelCount = 2

    /// How many frames of history are kept, which bounds the longest usable delay.
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Every frame ever written, which numbers the frames for `sample(channel:atFrame:)`.
    public private(set) var framesWritten = 0

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity * Self.channelCount)
        storage.initialize(repeating: 0, count: capacity * Self.channelCount)
    }

    deinit {
        storage.deallocate()
    }

    /// Appends interleaved frames. Mono is copied to both sides; channels past two are dropped.
    public func write(_ source: UnsafePointer<Float>, frameCount: Int, sourceChannels: Int) {
        guard sourceChannels > 0 else {
            writeSilence(frameCount: frameCount)
            return
        }

        for frame in 0..<frameCount {
            let slot = (framesWritten % capacity) * Self.channelCount
            let left = source[frame * sourceChannels]
            let right = sourceChannels > 1 ? source[frame * sourceChannels + 1] : left
            storage[slot] = left
            storage[slot + 1] = right
            framesWritten += 1
        }
    }

    public func writeSilence(frameCount: Int) {
        for _ in 0..<frameCount {
            let slot = (framesWritten % capacity) * Self.channelCount
            storage[slot] = 0
            storage[slot + 1] = 0
            framesWritten += 1
        }
    }

    /// One sample by its frame number, or silence once it has left the history. Safe to call
    /// from another thread for frames well behind the newest one.
    public func sample(channel: Int, atFrame frame: Int) -> Float {
        let newest = framesWritten
        guard frame >= 0, frame < newest, frame >= newest - capacity else {
            return 0
        }
        return storage[(frame % capacity) * Self.channelCount + channel % Self.channelCount]
    }

    /// One sample from the history. `framesAgo` 1 is the newest frame written.
    /// Anything older than the history, or not written yet, reads as silence.
    public func sample(channel: Int, framesAgo: Int) -> Float {
        guard framesAgo >= 1, framesAgo <= capacity, framesAgo <= framesWritten else {
            return 0
        }
        let frame = (framesWritten - framesAgo) % capacity
        return storage[frame * Self.channelCount + channel % Self.channelCount]
    }
}
