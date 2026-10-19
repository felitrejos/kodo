import CoreAudio
import Foundation
import KodoCore

/// Listens to the music for a few seconds to see whether a group's speakers have drifted
/// apart, and by how much. No chirps: it compares what the microphone hears with what Kodo
/// played.
@MainActor
struct SyncChecker {
    static let listenSeconds = 3.0
    /// The slowest arrival worth looking for after a frame leaves Kodo.
    static let maximumLatency = 0.6
    /// How far one speaker is moved to tell its arrival apart from the others.
    static let shift = 0.005

    enum Result: Equatable {
        case inStep
        /// Extra delay to add per speaker UID.
        case corrected([String: Double])
        /// Too quiet, too noisy, or too far off to trust; Fine-tune can sort it out.
        case unclear
    }

    let engine: UnisonEngine
    let microphone: AudioDevice
    let outputs: [AudioDevice]
    /// Plays the group's normal delays with this speaker moved `shift` later, or with no
    /// speaker moved.
    let moveSpeaker: (AudioDevice?) -> Void

    func check() async throws -> Result {
        let recorder = MicrophoneRecorder(device: microphone, maximumSeconds: Double(outputs.count + 1) * 5 + 5)
        try recorder.start()
        defer {
            recorder.stop()
            moveSpeaker(nil)
        }
        try await Task.sleep(for: .milliseconds(300))

        let baseline = try await listen(with: recorder)
        guard !baseline.isEmpty else {
            return .unclear
        }
        var moved: [String: [Double]] = [:]
        for output in outputs {
            moveSpeaker(output)
            // Let the crossfade to the moved delay finish before listening.
            try await Task.sleep(for: .milliseconds(100))
            moved[output.uid] = try await listen(with: recorder)
        }
        moveSpeaker(nil)

        guard let arrivals = SyncCheck.arrivals(baseline: baseline, shifted: moved, shift: Self.shift) else {
            return .unclear
        }
        let spread = (arrivals.values.max() ?? 0) - (arrivals.values.min() ?? 0)
        if spread < SyncCheck.tolerance {
            return .inStep
        }
        return SyncCheck.corrections(for: arrivals).map(Result.corrected) ?? .unclear
    }

    /// The arrival times, in seconds after Kodo played it, of each copy of the music the
    /// microphone heard. Empty when the music was too quiet to go by.
    private func listen(with recorder: MicrophoneRecorder) async throws -> [Double] {
        let start = AudioGetCurrentHostTime()
        try await Task.sleep(for: .seconds(Self.listenSeconds + 0.1))
        // Read the played music right away, while it's still in the history.
        guard let program = engine.program(from: start, seconds: Self.listenSeconds), loudness(of: program) > 0.003 else {
            return []
        }
        let heard = try await recorder.samples(from: start, seconds: Self.listenSeconds + Self.maximumLatency)
        let rate = recorder.sampleRate
        let reference = MusicAligner.resample(program, from: engine.sampleRate, to: rate)
        let lags = MusicAligner.arrivals(
            of: reference, in: heard,
            maximumLag: Int(Self.maximumLatency * rate),
            separation: Int(SyncCheck.tolerance * rate))
        return lags.map { Double($0) / rate }
    }

    private func loudness(of samples: [Float]) -> Float {
        guard !samples.isEmpty else {
            return 0
        }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}
