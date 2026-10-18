import CoreAudio
import Foundation
import Synchronization

/// Records one microphone channel during calibration, stamped with host time.
///
/// The microphone runs on its own clock, outside the playback aggregate. Host time is the
/// common ruler: the engine reports when each chirp left, this reports when each sample came in.
/// Keeping the microphone out of the aggregate also means the menu bar's recording indicator
/// only lights up while calibrating.
final class MicrophoneRecorder: @unchecked Sendable {
    let device: AudioDevice
    let sampleRate: Double
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let framesRecorded = Atomic<Int>(0)
    /// Host time of the first recorded frame. Written once by the audio thread before the
    /// first `framesRecorded` release, so readers that see frames also see this.
    private var firstFrameHostTime: UInt64 = 0
    private var procID: AudioDeviceIOProcID?

    init(device: AudioDevice, maximumSeconds: Double) {
        self.device = device
        sampleRate = device.nominalSampleRate
        capacity = Int(maximumSeconds * sampleRate)
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
    }

    deinit {
        stop()
        samples.deallocate()
    }

    func start() throws {
        var procID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { [unowned self] _, input, inputTime, _, _ in
                record(input, at: inputTime)
            },
            "Opening \(device.name)")
        guard let procID else {
            throw AudioError(operation: "Starting \(device.name)", status: kAudioHardwareUnspecifiedError)
        }
        do {
            try check(AudioDeviceStart(device.id, procID), "Starting \(device.name)")
        } catch {
            AudioDeviceDestroyIOProcID(device.id, procID)
            throw error
        }
        self.procID = procID
    }

    func stop() {
        guard let procID else {
            return
        }
        AudioDeviceStop(device.id, procID)
        AudioDeviceDestroyIOProcID(device.id, procID)
        self.procID = nil
    }

    /// The recording from `hostTime` onward, waiting until all of it has been captured.
    func samples(from hostTime: UInt64, seconds: Double) async throws -> [Float] {
        let deadline = ContinuousClock.now + .seconds(seconds + 2)
        while true {
            let recorded = framesRecorded.load(ordering: .acquiring)
            if recorded > 0 {
                let start = frame(at: hostTime)
                let end = start + Int(seconds * sampleRate)
                guard start >= 0, end <= capacity else {
                    throw RecorderError.outsideRecording
                }
                if end <= recorded {
                    return Array(UnsafeBufferPointer(start: samples + start, count: end - start))
                }
            }
            guard ContinuousClock.now < deadline else {
                throw RecorderError.noInput(device.name)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func frame(at hostTime: UInt64) -> Int {
        let nanoseconds = Double(AudioConvertHostTimeToNanos(hostTime)) - Double(AudioConvertHostTimeToNanos(firstFrameHostTime))
        return Int((nanoseconds / 1e9 * sampleRate).rounded())
    }

    // MARK: - Audio thread

    private func record(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard
            let buffer = buffers.first,
            let data = buffer.mData?.assumingMemoryBound(to: Float.self),
            buffer.mNumberChannels > 0
        else {
            return
        }

        let recorded = framesRecorded.load(ordering: .relaxed)
        if recorded == 0 {
            firstFrameHostTime = time.pointee.mHostTime
        }

        let channels = Int(buffer.mNumberChannels)
        let frameCount = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels), capacity - recorded)
        for frame in 0..<frameCount {
            samples[recorded + frame] = data[frame * channels]
        }
        framesRecorded.store(recorded + frameCount, ordering: .releasing)
    }
}

enum RecorderError: LocalizedError {
    case outsideRecording
    case noInput(String)

    var errorDescription: String? {
        switch self {
        case .outsideRecording: "The chirp fell outside the microphone recording."
        case .noInput(let name): "\(name) stopped sending audio. Check that Kodo can use the microphone."
        }
    }
}
