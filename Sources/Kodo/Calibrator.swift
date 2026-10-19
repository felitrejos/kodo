import Foundation
import KodoCore

/// What calibration learned about one output.
struct Measurement: Codable, Equatable {
    /// Seconds from the chirp leaving Kodo to it reaching the microphone. Only differences
    /// between outputs matter; the microphone's own latency is the same for all of them.
    var latency: Double
    /// Disagreement between runs, in seconds. A large spread means the room or mic was noisy.
    var spread: Double
    var strength: Float
}

/// What a fine-tune found for each speaker.
struct CalibrationOutcome {
    var measurements: [String: Measurement] = [:]
    /// Heard, but the runs disagreed too much to trust any of them.
    var unsteady: [String] = []
    /// Never heard clearly at all.
    var unheard: [String] = []
}

/// Plays a chirp through each output in turn and times its arrival at the microphone.
@MainActor
struct Calibrator {
    /// Several runs per output, interleaved so a passing noise only spoils one of them.
    static let runs = 5
    /// Runs that agree this closely count as the same answer.
    static let agreement = 0.003
    /// How many of the runs must agree before the answer is trusted.
    static let minimumAgreeing = 3

    let engine: UnisonEngine
    let microphone: AudioDevice

    /// - Parameter progress: Called with the output being measured and the fraction done.
    func measure(progress: (AudioDevice, Double) -> Void) async throws -> CalibrationOutcome {
        // How long after the chirp left to keep listening: the chirp itself plus the slowest
        // plausible output. AirPlay buffers about two seconds; Bluetooth stays well under one.
        let listenSeconds = Chirp.duration + (engine.outputs.contains { $0.transport == .airPlay } ? 3.0 : 1.0)
        let totalSteps = Self.runs * engine.outputs.count

        let recorder = MicrophoneRecorder(
            device: microphone,
            maximumSeconds: Double(totalSteps) * (listenSeconds + 0.5) + 5)
        let reference = Chirp.sweep(sampleRate: recorder.sampleRate)

        engine.setProgramMuted(true)
        defer { engine.setProgramMuted(false) }
        try recorder.start()
        defer { recorder.stop() }
        // Let the microphone settle and whatever was playing drain out of the delay buffers.
        try await Task.sleep(for: .milliseconds(600))

        var latencies: [String: [Double]] = [:]
        var strengths: [String: [Float]] = [:]
        var step = 0
        for _ in 0..<Self.runs {
            for output in engine.outputs {
                progress(output, Double(step) / Double(totalSteps))
                step += 1

                let sentAt = try await engine.playChirp(on: output)
                let heard = try await recorder.samples(from: sentAt, seconds: listenSeconds)
                guard
                    let arrival = ArrivalDetector.locate(reference, in: heard),
                    arrival.strength >= ArrivalDetector.minimumStrength
                else {
                    continue
                }
                latencies[output.uid, default: []].append(Double(arrival.frame) / recorder.sampleRate)
                strengths[output.uid, default: []].append(arrival.strength)

                // A short pause so this chirp's echoes die down before the next one.
                try await Task.sleep(for: .milliseconds(150))
            }
        }

        var outcome = CalibrationOutcome()
        for output in engine.outputs {
            guard let runs = latencies[output.uid], !runs.isEmpty else {
                outcome.unheard.append(output.uid)
                continue
            }
            guard let agreed = AlignmentPlan.consensus(runs, tolerance: Self.agreement, minimumAgreeing: Self.minimumAgreeing) else {
                outcome.unsteady.append(output.uid)
                continue
            }
            let strength = strengths[output.uid, default: []].max() ?? 0
            outcome.measurements[output.uid] = Measurement(latency: agreed.value, spread: agreed.spread, strength: strength)
        }
        return outcome
    }
}
