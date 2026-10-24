// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

@Suite(.tags(.engine, .automation), .serialized)
final class NodeAutomationTests: TestCaseModel {
    private let rate = GainRenderHarness.sampleRate

    @Test func refusesANodeWithoutAScheduler() {
        #expect(throws: (any Error).self) { try NodeAutomation(AVAudioPlayerNode()) }
    }

    @Test func publishingNothingStops() async throws {
        let channelGain = try await ChannelGain()
        let mapping = try TimelineMapping(renderAnchor: .sample(0), sourceAnchor: 0, renderSampleRate: rate)

        try channelGain.automation.publish([0: ParameterCurve(constant: 0.5)], mapping: mapping)
        #expect(channelGain.automation.isActive)
        #expect(channelGain.automation.mapping == mapping)

        channelGain.automation.publish([:], mapping: mapping)
        #expect(!channelGain.automation.isActive)
        #expect(channelGain.automation.mapping == nil)
    }

    /// A ramp is a move: once it ends and automation stops, the parameter stays where it went.
    @Test func rampLeavesTheParameterAtItsTarget() async throws {
        let stopAt = 24576
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: { try $0.automation.ramp(GainRenderHarness.gainAddresses, to: 0.3, duration: 0.1) },
            beforeBlock: { rendered, channelGain in
                if rendered == stopAt { channelGain.automation.stop() }
            }
        )

        #expect(abs(output[0][stopAt - 1] - 0.3) < 1e-6)
        let afterStop = Array(output[0][stopAt...])
        #expect(afterStop.allSatisfy { abs($0 - 0.3) < 1e-6 }, "moves after stopping: \(afterStop.min() ?? 0)…\(afterStop.max() ?? 0)")
    }

    @Test func rampTargetIsClampedToTheParameterRange() async throws {
        var gain: AUValue?
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 0.25), blockSize: 512,
            started: {
                try $0.automation.ramp(GainRenderHarness.gainAddresses, to: 1000, duration: 0.01)
                gain = $0.gain
            }
        )

        let maximum = ChannelGainParameter.defaultGainRange.upperBound
        #expect(gain == maximum)
        #expect(abs(output[0][output[0].count - 1] - maximum) < 1e-6)
    }
}
