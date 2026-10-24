// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// The render-thread scheduler, rendered offline: mappings, adoption and replacement.
@Suite(.tags(.engine, .automation), .serialized)
final class AutomationSchedulerRenderTests: TestCaseModel {
    private let rate = GainRenderHarness.sampleRate

    private func linear(from start: Double = 0, to end: Double, _ startValue: AUValue = 0, _ endValue: AUValue = 1) throws -> ParameterCurve {
        try ParameterCurve([CurveSegment(start: start, end: end, startValue: startValue, endValue: endValue)])
    }

    /// One mapping plays every iteration of a loop on its position, with no drift.
    @Test func loopWrapsOnEveryIteration() async throws {
        let curve = try linear(to: 0.1)
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 2.05), blockSize: 512,
            started: { try GainRenderHarness.publish(curve, on: $0, sourceAnchor: 0.02, loop: 0 ..< 0.1) }
        )

        let mapping = try TimelineMapping(renderAnchor: .sample(0), sourceAnchor: 0.02, loop: 0 ..< 0.1, renderSampleRate: rate)
        let expected = output[0].indices.map { curve.value(at: mapping.position(atRenderSample: Int64($0)) ?? .nan) }
        let error = CurveError(output[0], expected)
        reportMeasure("loop of 20 iterations", "\(error)")

        #expect(error.maxAbs <= 1e-6, "\(error)")
        // Iteration 20 begins at 1.98 s; 24 frames in, the ramp is at 24 / 4800.
        #expect(abs(output[0][Int(1.98 * rate) + 24] - 0.005) < 1e-4, "iteration 20 does not restart on time")
    }

    @Test func reverseMappingPlaysBackwards() async throws {
        let curve = try linear(to: 1)
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 0.9), blockSize: 512,
            started: { try GainRenderHarness.publish(curve, on: $0, sourceAnchor: 1, direction: .reverse) }
        )

        let error = CurveError(output[0], output[0].indices.map { Float(1 - Double($0) / rate) })
        #expect(error.maxAbs <= 1e-6, "\(error)")
    }

    /// An `.atAdoption` mapping starts on the first frame of the block that takes it.
    @Test func atAdoptionAnchorsOnTheAdoptingBlock() async throws {
        let publishAt = 24576
        let curve = try linear(to: 1)
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            beforeBlock: { rendered, channelGain in
                guard rendered == publishAt else { return }
                try GainRenderHarness.publish(curve, on: channelGain, anchor: .atAdoption)
            }
        )

        #expect(output[0][publishAt - 1] == 1)
        #expect(output[0][publishAt] == 0)
        #expect(abs(output[0][publishAt + 4800] - 0.1) < 1e-6)
    }

    /// A curve replacing a running one glides from where the old one was over 20 ms.
    @Test func replacementGlidesFromTheRunningValue() async throws {
        let replaceAt = 24576
        let glide = Int(0.02 * rate)
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: { try GainRenderHarness.publish(ParameterCurve(constant: 1), on: $0) },
            beforeBlock: { rendered, channelGain in
                guard rendered == replaceAt else { return }
                try GainRenderHarness.publish(ParameterCurve(constant: 0), on: channelGain)
            }
        )

        #expect(output[0][replaceAt - 1] == 1)
        #expect(abs(output[0][replaceAt] - 1) < 1e-6)
        #expect(abs(output[0][replaceAt + glide / 2] - 0.5) < 1e-6)
        #expect(output[0][replaceAt + glide] == 0)

        let step = Array(output[0][(replaceAt - 4) ..< (replaceAt + glide + 4)]).largestStep
        #expect(step.step <= 1 / Float(glide) + 1e-6, "steps \(step.step) at \(step.frame)")
    }

    /// Stopping returns each parameter to its own value over 20 ms.
    @Test func stopGlidesBackToTheManualValue() async throws {
        let stopAt = 24576
        let glide = Int(0.02 * rate)
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            configure: { $0.gain = 0.8 },
            started: { try GainRenderHarness.publish(ParameterCurve(constant: 0.5), on: $0) },
            beforeBlock: { rendered, channelGain in
                guard rendered == stopAt else { return }
                channelGain.automation.stop()
            }
        )

        #expect(abs(output[0][stopAt - 1] - 0.4) < 1e-6, "multiplies the manual value")
        #expect(abs(output[0][stopAt + glide / 2] - 0.6) < 1e-4)
        #expect(abs(output[0][stopAt + glide] - 0.8) < 1e-6)
        #expect(abs(output[0][output[0].count - 1] - 0.8) < 1e-6)
    }

    /// A start published just after a stop opens on its curve, not on the stop's glide back to the
    /// parameter's own value.
    @Test func aStartAfterAStopOpensOnItsCurve() async throws {
        let stopAt = 24576
        let mapping = try TimelineMapping(renderAnchor: .atAdoption, sourceAnchor: 0, renderSampleRate: rate)
        let curves = try Dictionary(uniqueKeysWithValues: GainRenderHarness.gainAddresses.map { ($0, try ParameterCurve(constant: 0.25)) })

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: { $0.automation.publish(curves, mapping: mapping, combine: .multiply) },
            beforeBlock: { rendered, channelGain in
                if rendered == stopAt { channelGain.automation.stop() }
                if rendered == stopAt + 512 { channelGain.automation.publish(curves, mapping: mapping, combine: .multiply, glides: false) }
            }
        )

        let opened = Array(output[0][(stopAt + 512)...])
        #expect(opened.allSatisfy { abs($0 - 0.25) < 1e-6 }, "opens at \(opened[0]), reaches \(opened.max() ?? 0)")
    }

    /// Publishes faster than the render thread adopts them: the last one wins, the rest are freed.
    @Test func manyPublishesBetweenBlocksAdoptTheLast() async throws {
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 0.5), blockSize: 512,
            beforeBlock: { rendered, channelGain in
                guard rendered % 2048 == 0 else { return }
                for i in 0 ... 40 {
                    try GainRenderHarness.publish(ParameterCurve(constant: AUValue(i) / 100), on: channelGain, anchor: .atAdoption)
                }
            }
        )

        #expect(abs(output[0][output[0].count - 1] - 0.4) < 1e-6)
    }

    /// Bypassed blocks still advance the automation, so it resumes on its position.
    @Test func bypassKeepsTheAutomationOnItsPosition() async throws {
        let curve = try linear(to: 1)
        let resumeAt = 24576
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 0.75), blockSize: 512,
            started: {
                try GainRenderHarness.publish(curve, on: $0)
                $0.isBypassed = true
            },
            beforeBlock: { rendered, channelGain in
                if rendered == resumeAt { channelGain.isBypassed = false }
            }
        )

        #expect(output[0][resumeAt - 1] == 1, "bypassed")
        #expect(abs(output[0][resumeAt] - Float(Double(resumeAt) / rate)) < 1e-6)
    }
}
