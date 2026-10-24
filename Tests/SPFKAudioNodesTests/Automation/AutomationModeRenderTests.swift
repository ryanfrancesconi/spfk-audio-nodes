// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// Who wins a replacing curve's parameter while a touch holds it (R7).
@Suite(.tags(.engine, .automation), .serialized)
final class AutomationModeRenderTests: TestCaseModel {
    private let rate = GainRenderHarness.sampleRate
    private let touchAt = 12288
    private let releaseAt = 24576
    private let republishAt = 36864
    private var glide: Int { Int(0.02 * rate) }

    private func render(mode: AutomationMode) async throws -> (output: [Float], curve: ParameterCurve) {
        let curve = try ParameterCurve([CurveSegment(start: 0, end: 1, startValue: 0, endValue: 1)])
        let mapping = try TimelineMapping(renderAnchor: .sample(0), sourceAnchor: 0, renderSampleRate: rate)
        let curves = Dictionary(uniqueKeysWithValues: GainRenderHarness.gainAddresses.map { ($0, curve) })

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: { $0.automation.publish(curves, mapping: mapping, combine: .replace, mode: mode) },
            beforeBlock: { rendered, channelGain in
                switch rendered {
                case self.touchAt:
                    channelGain.$leftGain.beginTouch(value: 0.2)
                    channelGain.$rightGain.beginTouch(value: 0.2)
                case self.releaseAt:
                    channelGain.$leftGain.endTouch()
                    channelGain.$rightGain.endTouch()
                case self.republishAt:
                    channelGain.automation.publish(curves, mapping: mapping, combine: .replace, mode: mode)
                default:
                    break
                }
            }
        )
        return (output[0], curve)
    }

    private func onCurve(_ output: [Float], _ curve: ParameterCurve, _ frames: Range<Int>) -> CurveError {
        CurveError(Array(output[frames]), frames.map { curve.value(at: Double($0) / self.rate) })
    }

    @Test func readIgnoresTheTouch() async throws {
        let (output, curve) = try await render(mode: .read)
        let error = onCurve(output, curve, 0 ..< output.count)
        #expect(error.maxAbs <= 1e-6, "\(error)")
    }

    @Test func touchHoldsTheParameterUntilRelease() async throws {
        let (output, curve) = try await render(mode: .touch)

        #expect(onCurve(output, curve, 0 ..< touchAt).maxAbs <= 1e-6)
        #expect(output[(touchAt + glide) ..< releaseAt].allSatisfy { abs($0 - 0.2) < 1e-6 }, "held at the touched value")
        #expect(onCurve(output, curve, (releaseAt + glide) ..< output.count).maxAbs <= 1e-6, "back on the curve")
        #expect(Array(output[(touchAt - 1) ..< (releaseAt + glide + 1)]).largestStep.step < 0.01, "glides in and out")
    }

    @Test func latchHoldsTheParameterUntilTheNextPublish() async throws {
        let (output, curve) = try await render(mode: .latch)

        #expect(onCurve(output, curve, 0 ..< touchAt).maxAbs <= 1e-6)
        #expect(output[(touchAt + glide) ..< republishAt].allSatisfy { abs($0 - 0.2) < 1e-6 }, "held past the release")
        #expect(onCurve(output, curve, (republishAt + glide) ..< output.count).maxAbs <= 1e-6, "back on the curve")
        #expect(Array(output[(republishAt - 1) ..< (republishAt + glide + 1)]).largestStep.step < 0.01)
    }

    /// A multiplying curve never yields: the touched value is what it multiplies.
    @Test func multiplyingCurveScalesTheTouchedValue() async throws {
        let curve = try ParameterCurve([CurveSegment(start: 0, end: 1, startValue: 0, endValue: 1)])
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: {
                try $0.automation.publish(
                    Dictionary(uniqueKeysWithValues: GainRenderHarness.gainAddresses.map { ($0, curve) }),
                    mapping: TimelineMapping(renderAnchor: .sample(0), sourceAnchor: 0, renderSampleRate: self.rate),
                    combine: .multiply, mode: .touch
                )
            },
            beforeBlock: { rendered, channelGain in
                if rendered == self.touchAt { channelGain.$leftGain.beginTouch(value: 0.5) }
            }
        )

        let settled = (touchAt + glide) ..< output[0].count
        let error = CurveError(Array(output[0][settled]), settled.map { 0.5 * curve.value(at: Double($0) / self.rate) })
        #expect(error.maxAbs <= 1e-6, "\(error)")
    }
}
