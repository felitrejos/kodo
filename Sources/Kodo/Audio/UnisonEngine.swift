import CoreAudio
import Foundation
import KodoCore

/// Plays the system tap through several outputs at once, each with its own delay and volume.
///
/// All outputs and the tap live in one private aggregate device. That puts them on a single
/// clock: Core Audio's drift compensation resamples every device that is not the clock source,
/// so outputs that start aligned stay aligned over a long session.
@MainActor
final class UnisonEngine {
    /// Bluetooth needs a few hundred milliseconds and AirPlay about two seconds, so four
    /// seconds of history covers anything you would actually want to line up.
    static let historySeconds = 4.0

    let outputs: [AudioDevice]
    let sampleRate: Double
    private let aggregateID: AudioObjectID
    private let state: RenderState
    private var procID: AudioDeviceIOProcID?
    /// Rates the outputs ran at before Kodo switched them, restored on teardown.
    private let originalSampleRates: [AudioDevice: Double]

    init(outputs: [AudioDevice], tap: SystemAudioTap) throws {
        guard !outputs.isEmpty else {
            throw EngineError.noOutputs
        }

        // The built-in speakers have the steadiest clock and the lowest latency, so they make a
        // good reference. Bluetooth devices drift and get resampled against it.
        let clockDevice = outputs.first { $0.transport == .builtIn } ?? outputs[0]
        let originalSampleRates = Dictionary(uniqueKeysWithValues: outputs.map { ($0, $0.nominalSampleRate) })
        self.originalSampleRates = originalSampleRates
        do {
            sampleRate = try Self.prepareCommonSampleRate(for: outputs, preferring: clockDevice)
        } catch {
            Self.restore(originalSampleRates)
            throw error
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kodo",
            kAudioAggregateDeviceUIDKey: "kodo.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: outputs.map { output in
                [
                    kAudioSubDeviceUIDKey: output.uid,
                    kAudioSubDeviceDriftCompensationKey: output.uid != clockDevice.uid,
                ] as [String: Any]
            },
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: true] as [String: Any],
            ],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "Creating the Kodo device")
        } catch {
            Self.restore(originalSampleRates)
            throw error
        }
        self.aggregateID = aggregateID
        self.outputs = outputs

        do {
            let bufferGroups = try Self.bufferGroups(aggregateID: aggregateID, outputs: outputs)
            state = RenderState(
                bufferGroups: bufferGroups,
                groupCount: outputs.count,
                chirp: Chirp.sweep(sampleRate: sampleRate),
                clicks: ClickTrain.samples(sampleRate: sampleRate),
                historyFrames: Int(Self.historySeconds * sampleRate))
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            Self.restore(originalSampleRates)
            throw error
        }
    }

    isolated deinit {
        stop()
        AudioHardwareDestroyAggregateDevice(aggregateID)
        Self.restore(originalSampleRates)
    }

    private static func restore(_ sampleRates: [AudioDevice: Double]) {
        for (output, rate) in sampleRates where rate > 0 {
            try? output.setNominalSampleRate(rate)
        }
    }

    func start() throws {
        guard procID == nil else {
            return
        }

        var procID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, Self.renderBlock(for: state)),
            "Setting up playback")
        guard let procID else {
            throw AudioError(operation: "Starting playback", status: kAudioHardwareUnspecifiedError)
        }
        do {
            try check(AudioDeviceStart(aggregateID, procID), "Starting playback")
        } catch {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            throw error
        }
        self.procID = procID
    }

    /// Built outside the main actor: a closure formed in an isolated method inherits that
    /// isolation, and Swift traps when the audio thread calls it.
    private nonisolated static func renderBlock(for state: RenderState) -> AudioDeviceIOBlock {
        { _, input, _, output, outputTime in
            state.render(input: input, output: output, outputTime: outputTime)
        }
    }

    func stop() {
        guard let procID else {
            return
        }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        self.procID = nil
    }

    /// The longest delay currently applied, in seconds.
    private(set) var longestDelay = 0.0

    /// Applies delays and volumes keyed by device UID. Outputs not in the dictionaries get no delay.
    func apply(delays: [String: Double], gains: [String: Float]) {
        longestDelay = outputs.map { delays[$0.uid] ?? 0 }.max() ?? 0
        for (group, output) in outputs.enumerated() {
            let frames = Int((delays[output.uid] ?? 0) * sampleRate)
            state.setDelay(frames: frames, gain: gains[output.uid] ?? 1, forGroup: group)
        }
    }

    var diagnostics: (cycles: Int, capturedPeak: Float, streams: [Int]) {
        (
            state.cycles.load(ordering: .relaxed),
            Float(bitPattern: state.capturedPeakBits.load(ordering: .relaxed)),
            aggregateID.streamChannelCounts(scope: kAudioObjectPropertyScopeOutput)
        )
    }

    /// Silences the captured audio so calibration chirps play into a quiet room.
    func setProgramMuted(_ muted: Bool) {
        state.programMuted.store(muted, ordering: .relaxed)
    }

    /// Plays the calibration chirp on one output and returns the host time its first frame left.
    func playChirp(on output: AudioDevice) async throws -> UInt64 {
        guard let group = outputs.firstIndex(of: output) else {
            throw EngineError.unknownOutput(output.name)
        }

        state.chirpGroup.store(group, ordering: .relaxed)
        try await play(.chirp, lasting: Chirp.duration)
        return state.chirpHostTime.load(ordering: .relaxed)
    }

    /// Plays the click test through every output at its own delay and volume, in place of the
    /// captured audio, and returns once the last click has left the slowest output.
    func playTestClicks() async throws {
        try await play(.clicks, lasting: Double(ClickTrain.clickCount) * ClickTrain.interval)
        try await Task.sleep(for: .seconds(longestDelay))
    }

    private func play(_ signal: RenderState.Signal, lasting seconds: Double) async throws {
        state.setPhase(.requested, of: signal)
        // Hand the audio back to the captured mix however this ends, including cancellation.
        defer { state.setPhase(.idle, of: signal) }

        let deadline = ContinuousClock.now + .seconds(seconds + 2)
        while state.phase(of: signal) != .finished {
            guard ContinuousClock.now < deadline else {
                throw EngineError.signalTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Setup

    /// Aggregates need their members at the same nominal rate. Keep the clock device's current
    /// rate when everyone can follow it, so the built-in speakers are not switched needlessly.
    private static func prepareCommonSampleRate(for outputs: [AudioDevice], preferring clockDevice: AudioDevice) throws -> Double {
        let candidates = [clockDevice.nominalSampleRate, 48_000, 44_100, 96_000, 88_200]
        guard let rate = candidates.first(where: { rate in rate > 0 && outputs.allSatisfy { $0.supports(sampleRate: rate) } }) else {
            throw EngineError.noCommonSampleRate
        }
        for output in outputs {
            try output.setNominalSampleRate(rate)
        }
        return rate
    }

    /// The aggregate lists each member's output streams back to back, in member order.
    private static func bufferGroups(aggregateID: AudioObjectID, outputs: [AudioDevice]) throws -> [Int] {
        let members = try aggregateID.readArray(kAudioAggregateDevicePropertyActiveSubDeviceList, of: AudioObjectID.self)
        var groups: [Int] = []
        for member in members {
            guard let group = outputs.firstIndex(where: { $0.id == member }) else {
                continue
            }
            let streamCount = member.streamChannelCounts(scope: kAudioObjectPropertyScopeOutput).count
            groups += Array(repeating: group, count: streamCount)
        }

        let aggregateStreams = aggregateID.streamChannelCounts(scope: kAudioObjectPropertyScopeOutput).count
        guard groups.count == aggregateStreams, Set(groups).count == outputs.count else {
            throw EngineError.unexpectedLayout
        }
        return groups
    }
}

enum EngineError: LocalizedError {
    case noOutputs
    case noCommonSampleRate
    case unexpectedLayout
    case unknownOutput(String)
    case signalTimedOut

    var errorDescription: String? {
        switch self {
        case .noOutputs: "Pick at least one speaker."
        case .noCommonSampleRate: "These speakers have no sample rate in common."
        case .unexpectedLayout: "Core Audio built the Kodo device differently than expected."
        case .unknownOutput(let name): "\(name) is not part of the current setup."
        case .signalTimedOut: "The test sound never finished playing."
        }
    }
}
