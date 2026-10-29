// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// The TimePitch node's parameters, bypass, latency and quality swap.
@Suite(.tags(.engine), .serialized)
final class TimePitchNodeTests: TestCaseModel {
    private let sampleRate = TimePitchRig.sampleRate

    private func dsp(_ timePitch: TimePitch) throws -> DSPRef {
        try #require((timePitch.avAudioNode.auAudioUnit as? SPFKAudioUnit)?.dsp)
    }

    @Test func everyParameterReadsBackFromTheDSP() async throws {
        let timePitch = try await TimePitch()
        timePitch.apply(TimePitchDescription(
            semitones: 3, cents: -12, rate: 1.25, tonalityLimitHz: 8000,
            formantCorrection: true, formantBaseHz: 200, formantSemitones: -4
        ))

        let dsp = try dsp(timePitch)
        let expected: [(TimePitchParameter, AUValue)] = [
            (.rate, 1.25), (.pitchCents, 288), (.tonalityLimit, 8000),
            (.formantShift, -4), (.formantCorrection, 1), (.formantBase, 200),
        ]
        for (parameter, value) in expected {
            #expect(getParameterValueDSP(dsp, parameter.rawValue) == value, "\(parameter)")
        }
    }

    @Test func scheduledParameterEventTakesEffect() async throws {
        let rig = try await TimePitchRig()
        let schedule = rig.timePitch.avAudioNode.auAudioUnit.scheduleParameterBlock
        schedule(AUEventSampleTimeImmediate, 0, TimePitchParameter.rate.rawValue, 0.75)

        _ = try rig.render(frames: 512)
        #expect(try getParameterValueDSP(dsp(rig.timePitch), TimePitchParameter.rate.rawValue) == 0.75)
    }

    @Test func bypassPassesSamplesThroughExactly() async throws {
        let input = try TimePitchRig.makeNoise(frames: 8192)
        let rig = try await TimePitchRig(throughMixer: false) {
            $0.rate = 0.5
            $0.pitchCents = 300
            $0.isBypassed = true
        }

        let output = try rig.play(input, frames: 8192)
        #expect(output == TimePitchRig.channels(input))
        #expect(rig.timePitch.avAudioNode.auAudioUnit.latency == 0)
        #expect(rig.timePitch.inputFramesPulled == 8192)
    }

    /// An impulse at source frame p is heard at p / rate + L(rate).
    @Test(arguments: [0.5, 1, 2] as [Double])
    func reportedLatencyMatchesAnImpulse(rate: Double) async throws {
        let impulseFrame = 9600
        let input = try TimePitchRig.makeClicks(frames: 48000, every: 48000, first: impulseFrame)
        let rig = try await TimePitchRig { $0.rate = AUValue(rate) }

        let latency = rig.timePitch.latency(atRate: rate)
        #expect(rig.timePitch.avAudioNode.auAudioUnit.latency == latency)

        let expected = Double(impulseFrame) / rate + latency * sampleRate
        let output = try rig.play(input, frames: Int(expected) + 4800)
        let measured = peakFrame(in: output[0], near: Int(expected.rounded()), radius: 2400)

        reportTimePitch("impulse \(rate)x", "measured \(measured), predicted \(expected), latency \(latency * 1000) ms")
        #expect(abs(Double(measured) - expected) <= 2)
    }

    @Test func qualitySwapsAtTheNextBlock() async throws {
        let rig = try await TimePitchRig { $0.rate = 0.75 }
        let input = try TimePitchRig.makeNoise(frames: 48000)
        rig.player.scheduleBuffer(input, completionHandler: nil)
        rig.player.play()
        _ = try rig.render(frames: 4096)

        let best = rig.timePitch.latency(atRate: 1)
        rig.timePitch.setQuality(.efficient)
        #expect(rig.timePitch.latency(atRate: 1) == best)

        _ = try rig.render(frames: 512)
        let efficient = rig.timePitch.latency(atRate: 1)
        #expect(efficient != best)
        reportTimePitch("latency at 1x", "best \(best * 1000) ms, efficient \(efficient * 1000) ms")

        // After the swap's one reset, the new kernel renders.
        let after = try rig.render(frames: 24000)
        #expect(after[0][12000...].contains { abs($0) > 0.01 })

        // A second swap frees the kernel the first one retired.
        rig.timePitch.setQuality(.best)
        _ = try rig.render(frames: 512)
        #expect(rig.timePitch.latency(atRate: 1) == best)
    }
}
