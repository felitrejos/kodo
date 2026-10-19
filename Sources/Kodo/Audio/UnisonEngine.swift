import CoreAudio
import Foundation
import KodoCore

/// Plays the captured taps through several outputs at once, each with its own delay and volume.
///
/// All outputs and the taps live in one private aggregate device. That puts them on a single
/// clock: Core Audio's drift compensation resamples every device that is not the clock source,
/// so outputs that start aligned stay aligned over a long session.
///
/// The aggregate also pads its faster members to match the slowest one's reported latency.
/// That gets an uncalibrated speaker roughly in step, but the reported numbers are only
/// approximate: the aggregate ignores the built-in speakers' stream latency, for one. Kodo's
/// calibration measures what's left and its delay line closes the gap.
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

    /// - Parameter taps: The global tap first, then any per-app taps; see `setTaps(_:)`.
    init(outputs: [AudioDevice], taps: [SystemAudioTap]) throws {
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
            // These flags must be numbers, as the headers say. A Swift Bool bridges to a
            // CFBoolean, which the drift key silently ignores, leaving the speaker uncorrected.
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: outputs.map { output in
                [
                    kAudioSubDeviceUIDKey: output.uid,
                    kAudioSubDeviceDriftCompensationKey: output.uid == clockDevice.uid ? 0 : 1,
                ] as [String: Any]
            },
            kAudioAggregateDeviceTapListKey: taps.map { tap in
                [kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: 1] as [String: Any]
            },
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

    /// Applies delays and volumes keyed by device UID. Outputs not in the dictionaries get no delay.
    func apply(delays: [String: Double], gains: [String: Float]) {
        for (group, output) in outputs.enumerated() {
            let frames = Int((delays[output.uid] ?? 0) * sampleRate)
            state.setDelay(frames: frames, gain: gains[output.uid] ?? 1, forGroup: group)
        }
    }

    var diagnostics: (cycles: Int, inputStreams: [Int], outputStreams: [Int]) {
        (
            state.cycles.load(ordering: .relaxed),
            aggregateID.streamChannelCounts(scope: kAudioObjectPropertyScopeInput),
            aggregateID.streamChannelCounts(scope: kAudioObjectPropertyScopeOutput)
        )
    }

    /// Swaps the taps while playing, so adjusting one app never interrupts the delay buffers.
    /// The renderer's inputs follow this order.
    func setTaps(_ taps: [SystemAudioTap]) throws {
        var address = AudioObjectID.address(kAudioAggregateDevicePropertyTapList)
        var list = Unmanaged.passRetained(taps.map(\.uid) as CFArray)
        defer { list.release() }
        try check(
            AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFArray>>.size), &list),
            "Updating Kodo's app taps")

        // Taps added this way start without drift compensation; give them the same as the rest.
        let subTaps = (try? aggregateID.readArray(kAudioAggregateDevicePropertySubTapList, of: AudioObjectID.self)) ?? []
        for subTap in subTaps {
            try? subTap.write(kAudioSubTapPropertyDriftCompensation, UInt32(1))
        }
    }

    func setGain(_ gain: Float, forInput input: Int) {
        state.setGain(gain, forInput: input)
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
        state.chirpPhase.store(RenderState.ChirpPhase.requested.rawValue, ordering: .releasing)

        let deadline = ContinuousClock.now + .seconds(Chirp.duration + 2)
        while state.chirpPhase.load(ordering: .acquiring) != RenderState.ChirpPhase.finished.rawValue {
            guard ContinuousClock.now < deadline else {
                state.chirpPhase.store(RenderState.ChirpPhase.idle.rawValue, ordering: .releasing)
                throw EngineError.chirpTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        state.chirpPhase.store(RenderState.ChirpPhase.idle.rawValue, ordering: .releasing)
        return state.chirpHostTime.load(ordering: .relaxed)
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
    case chirpTimedOut

    var errorDescription: String? {
        switch self {
        case .noOutputs: "Pick at least one speaker."
        case .noCommonSampleRate: "These speakers have no sample rate in common."
        case .unexpectedLayout: "Core Audio built the Kodo device differently than expected."
        case .unknownOutput(let name): "\(name) is not part of the current setup."
        case .chirpTimedOut: "The calibration chirp never finished playing."
        }
    }
}
