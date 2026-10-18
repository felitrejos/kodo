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

struct ClickTrainTests {
    @Test func spacesClicksEvenlyWithSilenceBetween() {
        let samples = ClickTrain.samples(sampleRate: 48_000)
        let interval = 24_000

        #expect(samples.count == ClickTrain.clickCount * interval)
        for index in 0..<ClickTrain.clickCount {
            let start = index * interval
            #expect(samples[start + 1..<start + 100].contains { abs($0) > 0.1 })
            #expect(samples[start + 1_000..<start + interval].allSatisfy { $0 == 0 })
        }
        #expect(samples.allSatisfy { abs($0) <= ClickTrain.amplitude })
    }
}
