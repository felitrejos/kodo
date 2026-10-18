import CoreAudio
import KodoCore
import Synchronization

/// Everything the audio thread touches, allocated up front so rendering never allocates or locks.
///
/// Delays and gains are plain memory written from the main thread and read on the audio thread.
/// A torn read is impossible for aligned word-sized values on Apple silicon, and a value that is
/// one cycle stale is harmless, so they skip the cost of atomics.
final class RenderState: @unchecked Sendable {
    enum ChirpPhase: Int {
        case idle, requested, playing, finished
    }

    let groupCount: Int
    let delayLine: DelayLine
    private let bufferGroups: UnsafeMutablePointer<Int>
    private let bufferCount: Int
    private let delays: UnsafeMutablePointer<Int>
    private let gains: UnsafeMutablePointer<Float>

    let programMuted = Atomic<Bool>(false)
    /// Render cycles so far, and the loudest captured sample as raw float bits. Diagnostics only.
    let cycles = Atomic<Int>(0)
    let capturedPeakBits = Atomic<UInt32>(0)

    private let chirp: UnsafeMutablePointer<Float>
    private let chirpLength: Int
    private var chirpPosition = 0
    let chirpPhase = Atomic<Int>(ChirpPhase.idle.rawValue)
    let chirpGroup = Atomic<Int>(0)
    /// Host time at which the chirp's first frame was handed to the outputs.
    let chirpHostTime = Atomic<UInt64>(0)

    /// - Parameter bufferGroups: For each output buffer the IOProc receives, which output it belongs to.
    init(bufferGroups groups: [Int], groupCount: Int, chirp samples: [Float], historyFrames: Int) {
        self.groupCount = groupCount
        delayLine = DelayLine(capacity: historyFrames)

        bufferCount = groups.count
        bufferGroups = .allocate(capacity: groups.count)
        bufferGroups.initialize(from: groups, count: groups.count)
        delays = .allocate(capacity: groupCount)
        delays.initialize(repeating: 0, count: groupCount)
        gains = .allocate(capacity: groupCount)
        gains.initialize(repeating: 1, count: groupCount)

        chirpLength = samples.count
        chirp = .allocate(capacity: samples.count)
        chirp.initialize(from: samples, count: samples.count)
    }

    deinit {
        bufferGroups.deallocate()
        delays.deallocate()
        gains.deallocate()
        chirp.deallocate()
    }

    func setDelay(frames: Int, gain: Float, forGroup group: Int) {
        delays[group] = min(max(frames, 0), delayLine.capacity - 8_192)
        gains[group] = gain
    }

    // MARK: - Audio thread

    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let first = outputs.first, first.mNumberChannels > 0 else {
            return
        }
        let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))

        captureProgram(from: input, frameCount: frameCount)
        let chirpGroup = startChirpIfRequested(outputTime: outputTime)

        for (bufferIndex, buffer) in outputs.enumerated() where bufferIndex < bufferCount {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            let group = bufferGroups[bufferIndex]
            let channels = Int(buffer.mNumberChannels)
            let delay = delays[group]
            let gain = gains[group]

            for frame in 0..<frameCount {
                let framesAgo = frameCount - frame + delay
                let left = delayLine.sample(channel: 0, framesAgo: framesAgo) * gain
                let right = delayLine.sample(channel: 1, framesAgo: framesAgo) * gain
                let chirpSample = group == chirpGroup ? chirpSample(at: frame) : 0

                for channel in 0..<channels {
                    let program: Float = switch (channels, channel) {
                    case (1, _): (left + right) / 2
                    case (_, 0): left
                    case (_, 1): right
                    default: 0
                    }
                    data[frame * channels + channel] = program + chirpSample
                }
            }
        }

        advanceChirp(by: frameCount, playing: chirpGroup >= 0)
        cycles.add(1, ordering: .relaxed)
    }

    private func captureProgram(from input: UnsafePointer<AudioBufferList>, frameCount: Int) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        // The aggregate has no input devices, so the only input stream is the tap.
        guard
            !programMuted.load(ordering: .relaxed),
            let tap = inputs.first,
            let samples = tap.mData?.assumingMemoryBound(to: Float.self),
            tap.mNumberChannels > 0
        else {
            delayLine.writeSilence(frameCount: frameCount)
            return
        }

        let available = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * Int(tap.mNumberChannels))
        let usable = min(available, frameCount)
        delayLine.write(samples, frameCount: usable, sourceChannels: Int(tap.mNumberChannels))

        var peak: Float = 0
        for index in 0..<usable * Int(tap.mNumberChannels) {
            peak = max(peak, abs(samples[index]))
        }
        if peak > Float(bitPattern: capturedPeakBits.load(ordering: .relaxed)) {
            capturedPeakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        delayLine.writeSilence(frameCount: frameCount - usable)
    }

    /// Returns the group the chirp plays on during this cycle, or -1.
    private func startChirpIfRequested(outputTime: UnsafePointer<AudioTimeStamp>) -> Int {
        switch ChirpPhase(rawValue: chirpPhase.load(ordering: .acquiring)) {
        case .requested:
            chirpPosition = 0
            chirpHostTime.store(outputTime.pointee.mHostTime, ordering: .relaxed)
            chirpPhase.store(ChirpPhase.playing.rawValue, ordering: .releasing)
            return chirpGroup.load(ordering: .relaxed)
        case .playing:
            return chirpGroup.load(ordering: .relaxed)
        default:
            return -1
        }
    }

    private func chirpSample(at frame: Int) -> Float {
        let position = chirpPosition + frame
        return position < chirpLength ? chirp[position] : 0
    }

    private func advanceChirp(by frameCount: Int, playing: Bool) {
        guard playing else {
            return
        }
        chirpPosition += frameCount
        if chirpPosition >= chirpLength {
            chirpPhase.store(ChirpPhase.finished.rawValue, ordering: .releasing)
        }
    }
}
