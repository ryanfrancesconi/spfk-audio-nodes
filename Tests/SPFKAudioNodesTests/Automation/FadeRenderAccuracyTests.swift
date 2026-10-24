// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// A fade as played, against the same fade as rendered to a file — offline, with an exact anchor,
/// so only the curve, its sampling and its edges are measured.
@Suite(.tags(.engine, .automation), .serialized)
final class FadeRenderAccuracyTests: TestCaseModel {
    enum Direction: String, CaseIterable, Sendable { case fadeIn, fadeOut }

    private let rate = GainRenderHarness.sampleRate

    private func exactGain(_ fade: FadeDescription, regionDuration: TimeInterval, at position: TimeInterval) -> Float {
        if fade.inTime > 0, position < fade.inTime {
            return Float(fade.inTaper.gain(at: position / fade.inTime))
        }
        let outStart = regionDuration - fade.outTime
        if fade.outTime > 0, position >= outStart {
            return Float(fade.outTaper.fadeOutGain(at: (position - outStart) / fade.outTime))
        }
        return 1
    }

    // MARK: - Sampling (fact 4)

    static let samplingCases: [(taper: Int, seconds: TimeInterval, direction: Direction)] =
        AudioTaper.presets.indices.flatMap { taper in
            [0.1, 0.5, 2, 10].flatMap { seconds in Direction.allCases.map { (taper, seconds, $0) } }
        }

    /// A played fade is the rendered fade, frame for frame.
    @Test(arguments: samplingCases)
    func playedFadeMatchesRenderedFade(taper: Int, seconds: TimeInterval, direction: Direction) async throws {
        let shape = try #require(AudioTaper.preset(at: taper))
        let fade = direction == .fadeIn
            ? FadeDescription(inTime: seconds, inTaper: shape)
            : FadeDescription(outTime: seconds, outTaper: shape)

        let input = try GainRenderHarness.makeDC(seconds: seconds + 0.1)
        let duration = Double(input.frameLength) / rate
        let curve = try fade.curve(regionDuration: duration)

        let output = try await GainRenderHarness.render(
            input, blockSize: 512,
            started: { try GainRenderHarness.publish(curve, on: $0) }
        )

        let rendered = try GainRenderHarness.channels(
            input.fade(inTime: fade.inTime, outTime: fade.outTime, inTaper: fade.inTaper, outTaper: fade.outTaper)
        )

        let error = CurveError(output[0], rendered[0])
        reportMeasure("sampling taper=\(taper) \(seconds)s \(direction.rawValue)", "\(error)")

        #expect(error.maxAbs <= 1e-6, "\(error)")
    }

    // MARK: - Starting mid-fade (fact 3)

    static let cropCases: [(taper: Int, direction: Direction)] =
        AudioTaper.presets.indices.flatMap { taper in Direction.allCases.map { (taper, $0) } }

    /// Playing from inside a 2 s fade opens at the curve's value there and follows it.
    @Test(arguments: cropCases)
    func startingMidFadeFollowsTheCurve(taper: Int, direction: Direction) async throws {
        let shape = try #require(AudioTaper.preset(at: taper))
        let regionDuration: TimeInterval = 4
        let fade: FadeDescription
        let position: TimeInterval

        switch direction {
        case .fadeIn:
            fade = FadeDescription(inTime: 2, inTaper: shape)
            position = 0.5
        case .fadeOut:
            fade = FadeDescription(outTime: 2, outTaper: shape)
            position = 2.5
        }

        let curve = try fade.curve(regionDuration: regionDuration)
        let input = try GainRenderHarness.makeDC(seconds: 1)

        let output = try await GainRenderHarness.render(
            input, blockSize: 512,
            started: { try GainRenderHarness.publish(curve, on: $0, sourceAnchor: position) }
        )

        let window = Int(0.25 * rate)
        let exact = (0 ..< window).map { exactGain(fade, regionDuration: regionDuration, at: position + Double($0) / rate) }
        let measured = Array(output[0][0 ..< window])
        let error = CurveError(measured, exact)
        let step = measured.largestStep

        reportMeasure(
            "crop taper=\(taper) \(direction.rawValue)",
            String(format: "opens at %.5f (exact %.5f); largest step %.5f at frame %d; first 0.25 s: ",
                   measured[0], exact[0], step.step, step.frame) + error.description
        )

        #expect(error.maxAbs <= 1e-6, "\(error)")
        #expect(abs(measured[0] - exact[0]) <= 1e-6, "opens at \(measured[0]), exact \(exact[0])")
    }

    // MARK: - A set during automation (fact 6)

    /// The rendered value reads back what the automation reached; `gain` reads the manual value
    /// the automation multiplies.
    @Test func gainReadsBackWhatTheRampReached() async throws {
        let curve = try FadeDescription(inTime: 2).curve(regionDuration: 4)
        let input = try GainRenderHarness.makeDC(seconds: 1)
        let readAt = 24576

        var reads: (rendered: AUValue, gain: AUValue)?

        let output = try await GainRenderHarness.render(
            input, blockSize: 512,
            configure: { $0.gain = 0.8 },
            started: { try GainRenderHarness.publish(curve, on: $0) },
            beforeBlock: { rendered, channelGain in
                guard rendered == readAt + 512 else { return }
                reads = (channelGain.automation.renderedValue(of: ChannelGainParameter.leftGain.rawValue), channelGain.gain)
            }
        )

        let reached = output[0][readAt + 511]
        let read = try #require(reads)
        reportMeasure("readback mid-ramp", String(format: "rendered %.5f; read %.5f, gain %.5f", reached, read.rendered, read.gain))

        #expect(abs(read.rendered - reached) < 1e-6, "rendered value read \(read.rendered), ramp at \(reached)")
        #expect(read.gain == 0.8, "gain reads the manual value")
    }

    /// A gain write during a fade moves the value the fade multiplies, so the fade carries on from
    /// the new level rather than being interrupted (R7, `.multiply`).
    @Test func gainSetDuringAFadeScalesIt() async throws {
        let curve = try FadeDescription(inTime: 2).curve(regionDuration: 4)
        let input = try GainRenderHarness.makeDC(seconds: 2.5)
        let setAt = 49152
        let dezipper = Int(0.02 * rate)

        let output = try await GainRenderHarness.render(
            input, blockSize: 512,
            started: { try GainRenderHarness.publish(curve, on: $0) },
            beforeBlock: { rendered, channelGain in
                if rendered == setAt { channelGain.gain = 0.9 }
            }
        )

        let fade = { (frame: Int) in curve.value(at: Double(frame) / self.rate) }
        let before = CurveError(Array(output[0][0 ..< setAt]), (0 ..< setAt).map(fade))
        let settled = setAt + dezipper ..< output[0].count
        let after = CurveError(Array(output[0][settled]), settled.map { 0.9 * fade($0) })
        reportMeasure("set during fade", "before \(before); after \(after)")

        #expect(before.maxAbs <= 1e-6, "before the write: \(before)")
        #expect(after.maxAbs <= 1e-6, "after the write: \(after)")
        #expect(Array(output[0][setAt - 1 ..< setAt + dezipper + 1]).largestStep.step < 0.001)
    }
}
