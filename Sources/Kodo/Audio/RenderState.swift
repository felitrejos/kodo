import CoreAudio
import KodoCore
import Synchronization

/// Everything the audio thread touches, allocated up front so rendering never allocates or locks.
///
/// Delays and gains are plain memory written from the main thread and read on the audio thread.
/// A torn read is impossible for aligned word-sized values on Apple silicon, and a value that is
/// one cycle stale is harmless, so they skip the cost of atomics.
final class RenderState: @unchecked Sendable {
    /// Progress of a one-shot signal (the calibration chirp or the click test), handed back and
    /// forth between the main thread and the audio thread.
    enum SignalPhase: Int {
        case idle, requested, playing, finished
    }

    let groupCount: Int
    let delayLine: DelayLine
    private let bufferGroups: UnsafeMutablePointer<Int>
    private let bufferCount: Int
    private let delays: UnsafeMutablePointer<Int>
    private let gains: UnsafeMutablePointer<Float>
    /// The gain each output actually played at last cycle. Each cycle ramps from it to the
    /// target, so muting or dragging the slider fades over one buffer instead of clicking.
    private let playedGains: UnsafeMutablePointer<Float>

    let programMuted = Atomic<Bool>(false)
    /// Render cycles so far, and the loudest captured sample as raw float bits. Diagnostics only.
    let cycles = Atomic<Int>(0)
    let capturedPeakBits = Atomic<UInt32>(0)

    private let chirp: UnsafeMutablePointer<Float>
    private let chirpLength: Int
    private var chirpPosition = 0
    let chirpPhase = Atomic<Int>(SignalPhase.idle.rawValue)
    let chirpGroup = Atomic<Int>(0)
    /// Host time at which the chirp's first frame was handed to the outputs.
    let chirpHostTime = Atomic<UInt64>(0)

    private let clicks: UnsafeMutablePointer<Float>
    private let clicksLength: Int
    private var clicksPosition = 0
    let clicksPhase = Atomic<Int>(SignalPhase.idle.rawValue)

    /// - Parameters:
    ///   - bufferGroups: For each output buffer the IOProc receives, which output it belongs to.
    ///   - chirp: Calibration signal, played on one output with no delay.
    ///   - clicks: Test signal, fed in place of the captured audio so every output plays it at
    ///     its own delay, exactly like music.
    init(bufferGroups groups: [Int], groupCount: Int, chirp samples: [Float], clicks clickSamples: [Float], historyFrames: Int) {
        self.groupCount = groupCount
        delayLine = DelayLine(capacity: historyFrames)

        bufferCount = groups.count
        bufferGroups = .allocate(capacity: groups.count)
        bufferGroups.initialize(from: groups, count: groups.count)
        delays = .allocate(capacity: groupCount)
        delays.initialize(repeating: 0, count: groupCount)
        gains = .allocate(capacity: groupCount)
        gains.initialize(repeating: 1, count: groupCount)
        playedGains = .allocate(capacity: groupCount)
        playedGains.initialize(repeating: 1, count: groupCount)

        chirpLength = samples.count
        chirp = .allocate(capacity: samples.count)
        chirp.initialize(from: samples, count: samples.count)

        clicksLength = clickSamples.count
        clicks = .allocate(capacity: clickSamples.count)
        clicks.initialize(from: clickSamples, count: clickSamples.count)
    }

    deinit {
        bufferGroups.deallocate()
        delays.deallocate()
        gains.deallocate()
        playedGains.deallocate()
        chirp.deallocate()
        clicks.deallocate()
    }

    enum Signal {
        case chirp, clicks
    }

    func phase(of signal: Signal) -> SignalPhase {
        let raw = switch signal {
        case .chirp: chirpPhase.load(ordering: .acquiring)
        case .clicks: clicksPhase.load(ordering: .acquiring)
        }
        return SignalPhase(rawValue: raw) ?? .idle
    }

    func setPhase(_ phase: SignalPhase, of signal: Signal) {
        switch signal {
        case .chirp: chirpPhase.store(phase.rawValue, ordering: .releasing)
        case .clicks: clicksPhase.store(phase.rawValue, ordering: .releasing)
        }
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
            let startGain = playedGains[group]
            let gainStep = (gains[group] - startGain) / Float(frameCount)

            for frame in 0..<frameCount {
                let framesAgo = frameCount - frame + delay
                let gain = startGain + gainStep * Float(frame + 1)
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

        for group in 0..<groupCount {
            playedGains[group] = gains[group]
        }
        advanceChirp(by: frameCount, playing: chirpGroup >= 0)
        cycles.add(1, ordering: .relaxed)
    }

    private func captureProgram(from input: UnsafePointer<AudioBufferList>, frameCount: Int) {
        if feedClicksIfPlaying(frameCount: frameCount) {
            return
        }

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

    /// Writes the next stretch of the click test into the delay line instead of the captured
    /// audio. Returns false when no test is running.
    private func feedClicksIfPlaying(frameCount: Int) -> Bool {
        switch SignalPhase(rawValue: clicksPhase.load(ordering: .acquiring)) {
        case .requested:
            clicksPosition = 0
            clicksPhase.store(SignalPhase.playing.rawValue, ordering: .releasing)
        case .playing:
            break
        default:
            return false
        }

        let count = min(frameCount, clicksLength - clicksPosition)
        delayLine.write(clicks + clicksPosition, frameCount: count, sourceChannels: 1)
        delayLine.writeSilence(frameCount: frameCount - count)
        clicksPosition += count
        if clicksPosition >= clicksLength {
            clicksPhase.store(SignalPhase.finished.rawValue, ordering: .releasing)
        }
        return true
    }

    /// Returns the group the chirp plays on during this cycle, or -1.
    private func startChirpIfRequested(outputTime: UnsafePointer<AudioTimeStamp>) -> Int {
        switch SignalPhase(rawValue: chirpPhase.load(ordering: .acquiring)) {
        case .requested:
            chirpPosition = 0
            chirpHostTime.store(outputTime.pointee.mHostTime, ordering: .relaxed)
            chirpPhase.store(SignalPhase.playing.rawValue, ordering: .releasing)
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
            chirpPhase.store(SignalPhase.finished.rawValue, ordering: .releasing)
        }
    }
}
