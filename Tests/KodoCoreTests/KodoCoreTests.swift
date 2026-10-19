import Testing
@testable import KodoCore

struct ArrivalDetectorTests {
    /// Deterministic noise so a failing run can be reproduced.
    private struct SeededNoise {
        var state: UInt64

        mutating func next(amplitude: Float) -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amplitude * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    private func recording(
        chirp: [Float], at offset: Int, length: Int, gain: Float, noise amplitude: Float
    ) -> [Float] {
        var noise = SeededNoise(state: 42)
        var samples = (0..<length).map { _ in noise.next(amplitude: amplitude) }
        for (index, sample) in chirp.enumerated() where offset + index < length {
            samples[offset + index] += gain * sample
            // A weaker reflection 7 ms later, like a nearby wall.
            let echo = offset + index + 336
            if echo < length {
                samples[echo] += 0.4 * gain * sample
            }
        }
        return samples
    }

    @Test func findsChirpBuriedInNoise() throws {
        let chirp = Chirp.sweep(sampleRate: 48_000)
        let samples = recording(chirp: chirp, at: 9_617, length: 72_000, gain: 0.05, noise: 0.05)

        let arrival = try #require(ArrivalDetector.locate(chirp, in: samples))

        #expect(arrival.frame == 9_617)
        #expect(arrival.strength > ArrivalDetector.minimumStrength)
    }

    @Test func findsChirpAtStartOfRecording() throws {
        let chirp = Chirp.sweep(sampleRate: 44_100)
        let samples = recording(chirp: chirp, at: 0, length: 30_000, gain: 0.5, noise: 0.01)

        let arrival = try #require(ArrivalDetector.locate(chirp, in: samples))

        #expect(arrival.frame == 0)
    }

    @Test func reportsWeakStrengthForPureNoise() throws {
        let chirp = Chirp.sweep(sampleRate: 48_000)
        var noise = SeededNoise(state: 7)
        let samples = (0..<60_000).map { _ in noise.next(amplitude: 0.1) }

        let arrival = try #require(ArrivalDetector.locate(chirp, in: samples))

        #expect(arrival.strength < ArrivalDetector.minimumStrength)
    }

    @Test func rejectsRecordingShorterThanReference() {
        let chirp = Chirp.sweep(sampleRate: 48_000)

        #expect(ArrivalDetector.locate(chirp, in: Array(chirp.prefix(100))) == nil)
    }
}

struct ChirpTests {
    @Test func hasRequestedLengthAndStaysInRange() {
        let chirp = Chirp.sweep(sampleRate: 48_000)

        #expect(chirp.count == 19_200)
        #expect(chirp.allSatisfy { abs($0) <= Chirp.amplitude })
        #expect(abs(chirp[0]) < 0.001)
    }
}

struct AlignmentPlanTests {
    @Test func delaysFasterOutputsToMatchSlowest() {
        let delays = AlignmentPlan.delays(latencies: ["speakers": 0.010, "klipsch": 0.210, "jbl": 0.160])

        #expect(abs(delays["speakers", default: -1] - 0.200) < 1e-9)
        #expect(delays["klipsch"] == 0)
        #expect(abs(delays["jbl", default: -1] - 0.050) < 1e-9)
    }

    @Test func negativeTrimShiftsEveryoneLater() {
        let delays = AlignmentPlan.delays(
            latencies: ["speakers": 0.010, "klipsch": 0.210],
            trims: ["klipsch": -0.005, "unplugged": 1.0]
        )

        #expect(delays["klipsch"] == 0)
        #expect(abs(delays["speakers", default: -1] - 0.205) < 1e-9)
        #expect(delays["unplugged"] == nil)
    }

    @Test func emptyPlanIsEmpty() {
        #expect(AlignmentPlan.delays(latencies: [String: Double]()).isEmpty)
    }

    @Test func combineTakesMedian() {
        #expect(AlignmentPlan.combine([0.2, 0.9, 0.21]) == 0.21)
        #expect(AlignmentPlan.combine([0.2, 0.4]) == 0.30000000000000004)
        #expect(AlignmentPlan.combine([]) == nil)
        #expect(AlignmentPlan.spread([0.2, 0.9, 0.21]) == 0.7)
    }
}

struct DelayLineTests {
    @Test func readsBackWithDelayAndWrapsAround() {
        let line = DelayLine(capacity: 4)
        let first: [Float] = [1, -1, 2, -2, 3, -3]
        line.write(first, frameCount: 3, sourceChannels: 2)

        #expect(line.sample(channel: 0, framesAgo: 1) == 3)
        #expect(line.sample(channel: 1, framesAgo: 3) == -1)
        #expect(line.sample(channel: 0, framesAgo: 4) == 0)

        let mono: [Float] = [4, 5]
        line.write(mono, frameCount: 2, sourceChannels: 1)

        #expect(line.sample(channel: 1, framesAgo: 1) == 5)
        #expect(line.sample(channel: 0, framesAgo: 4) == 2)
        #expect(line.sample(channel: 0, framesAgo: 5) == 0)
    }
}

struct SoftClipTests {
    @Test func leavesNormalLevelsAlone() {
        #expect(SoftClip.apply(0.5) == 0.5)
        #expect(SoftClip.apply(-0.9) == -0.9)
    }

    @Test func neverExceedsFullScaleAndStaysSmooth() {
        let loud = SoftClip.apply(1.8)
        #expect(loud <= 1 && loud > 0.98)
        #expect(SoftClip.apply(-1.8) == -loud)
        #expect(SoftClip.apply(0.95) > SoftClip.apply(0.92))
    }
}

struct MusicAlignerTests {
    /// Noise with a little memory, closer to music than white noise is.
    private func music(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        var last: Float = 0
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Float(state >> 40) / Float(1 << 24) * 2 - 1
            last = 0.85 * last + 0.15 * white
            return last
        }
    }

    @Test func findsBothSpeakersInARecording() {
        let program = music(count: 48_000, seed: 3)
        var recording = [Float](repeating: 0, count: 48_000 + 24_000)
        for (index, sample) in program.enumerated() {
            recording[index + 12_000] += sample
            recording[index + 12_912] += 0.7 * sample
        }

        let arrivals = MusicAligner.arrivals(of: program, in: recording, maximumLag: 24_000, separation: 48)

        #expect(Set(arrivals.prefix(2)) == [12_000, 12_912])
    }

    @Test func resamplesToTheRequestedLength() {
        let samples = [Float](repeating: 1, count: 44_100)
        #expect(abs(MusicAligner.resample(samples, from: 44_100, to: 48_000).count - 48_000) <= 2)
    }
}

struct SyncCheckTests {
    @Test func attributesEachArrivalByWhichOneMoved() throws {
        let baseline = [0.250, 0.269]
        let shifted = ["klipsch": [0.255, 0.269], "speakers": [0.250, 0.274]]

        let arrivals = try #require(SyncCheck.arrivals(baseline: baseline, shifted: shifted, shift: 0.005))

        #expect(abs(arrivals["klipsch", default: 0] - 0.250) < 1e-9)
        #expect(abs(arrivals["speakers", default: 0] - 0.269) < 1e-9)
        let corrections = try #require(SyncCheck.corrections(for: arrivals))
        #expect(abs(corrections["klipsch", default: 0] - 0.019) < 1e-9)
        #expect(corrections["speakers"] == 0)
    }

    @Test func overlappingArrivalsSplitWhenShifted() throws {
        let arrivals = try #require(SyncCheck.arrivals(baseline: [0.250], shifted: ["a": [0.250, 0.255], "b": [0.250, 0.255]], shift: 0.005))
        #expect(arrivals == ["a": 0.250, "b": 0.250])
        #expect(SyncCheck.corrections(for: arrivals) == nil)
    }

    @Test func refusesAmbiguousOrLargeResults() {
        #expect(SyncCheck.arrivals(baseline: [0.25, 0.26], shifted: ["a": [0.31]], shift: 0.005) == nil)
        #expect(SyncCheck.corrections(for: ["a": 0.20, "b": 0.30]) == nil)
    }
}
