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

    /// The fade's events as `TransportPlayer.applyStoredFadeAutomation` builds them for a region of
    /// `regionDuration` played from `position`, and the gain it sets before automating.
    private func liveFade(
        _ fade: FadeDescription, regionDuration: TimeInterval, position: TimeInterval = 0
    ) -> (events: [AutomationEvent], initialGain: AUValue) {
        var description = RegionFadeDescription()
        description.fade = fade
        description.segmentDuration = regionDuration - position
        description.playbackStartOffset = position
        let initialGain = description.gainAt(playbackOffset: position)
        let events = (description.fadeInCurve()?.events ?? []) + (description.fadeOutCurve()?.events ?? [])
        return (events, initialGain)
    }

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

    /// Every way of reading the gain mid-ramp returns the value the ramp has reached.
    @Test func gainReadsBackWhatTheRampReached() async throws {
        let fade = FadeDescription(inTime: 2)
        let input = try GainRenderHarness.makeDC(seconds: 1)
        let live = liveFade(fade, regionDuration: 4)
        let readAt = 24576

        var reads: (gain: AUValue, tree: AUValue, dsp: AUValue)?

        let output = try await GainRenderHarness.render(
            input, blockSize: 512,
            configure: { $0.gain = live.initialGain },
            started: { try $0.automate(events: live.events, startTime: GainRenderHarness.renderStart) },
            beforeBlock: { rendered, channelGain in
                guard rendered == readAt + 512 else { return }
                let dsp = (channelGain.avAudioNode.auAudioUnit as? SPFKAudioUnit)?.dsp
                reads = (
                    channelGain.gain,
                    channelGain.leftGain,
                    dsp.map { getParameterValueDSP($0, ChannelGainParameter.leftGain.rawValue) } ?? .nan
                )
            }
        )

        let reached = output[0][readAt + 511]
        let read = try #require(reads)
        reportMeasure(
            "readback mid-ramp",
            String(format: "rendered %.5f; gain %.5f, parameter %.5f, DSP %.5f", reached, read.gain, read.tree, read.dsp)
        )

        withKnownIssue("no reader returns the automated value") {
            #expect(abs(read.gain - reached) < 1e-3, "gain read \(read.gain), ramp at \(reached)")
            #expect(abs(read.tree - reached) < 1e-3, "parameter read \(read.tree), ramp at \(reached)")
            #expect(abs(read.dsp - reached) < 1e-3, "DSP read \(read.dsp), ramp at \(reached)")
        }
    }

    /// What a bare gain write does to a running fade. Reference for R7: nothing specifies this today.
    @Test func gainSetMidRampRendersReference() async throws {
        let fade = FadeDescription(inTime: 2)
        let input = try GainRenderHarness.makeDC(seconds: 2.5)
        let live = liveFade(fade, regionDuration: 4)
        let setAt = 49152

        let output = try await GainRenderHarness.render(
            input, blockSize: 512,
            configure: { $0.gain = live.initialGain },
            started: { try $0.automate(events: live.events, startTime: GainRenderHarness.renderStart) },
            beforeBlock: { rendered, channelGain in
                if rendered == setAt { channelGain.gain = 0.9 }
            }
        )

        let after = Array(output[0][setAt ..< setAt + 1024])
        let exact = (setAt ..< setAt + 1024).map { exactGain(fade, regionDuration: 4, at: Double($0) / rate) }
        // The next segment boundary of a 2 s fade at 0.2 s resolution after the write.
        let resumes = Int(1.2 * rate)
        reportMeasure(
            "bare set mid-ramp",
            String(format: "before %.5f; +480 %.5f; +1023 %.5f (fade %.5f); at next segment (+%d) %.5f, fade %.5f",
                   output[0][setAt - 1], after[480], after[1023], exact[1023],
                   resumes - setAt, output[0][resumes + 1], exactGain(fade, regionDuration: 4, at: Double(resumes + 1) / rate))
        )
    }

    /// `update(normalize:)` mid-fade: the gain set, then the fade re-applied from the playhead with
    /// the node's last render as its anchor. The played curve should be the new fade, on the frame.
    @Test func reappliedFadeLandsOnThePlayhead() async throws {
        let input = try GainRenderHarness.makeDC(seconds: 2.5)
        let original = liveFade(FadeDescription(inTime: 2), regionDuration: 4)
        let applyAt = 49152
        let position = Double(applyAt) / rate
        let normalizedMax: AUValue = 2

        var description = RegionFadeDescription()
        description.fade = FadeDescription(inTime: 2)
        description.segmentDuration = 4 - position
        description.playbackStartOffset = position
        description.maximumGain = normalizedMax
        let reappliedGain = description.gainAt(playbackOffset: position)
        let reappliedEvents = description.fadeInCurve()?.events ?? []

        let output = try await GainRenderHarness.render(
            input, blockSize: 512,
            configure: { $0.gain = original.initialGain },
            started: { try $0.automate(events: original.events, startTime: GainRenderHarness.renderStart) },
            beforeBlock: { rendered, channelGain in
                guard rendered == applyAt else { return }
                channelGain.gain = reappliedGain
                try channelGain.automate(events: reappliedEvents, offset: 0)
            }
        )

        // Past the crop's first segment, where only the anchor decides the alignment.
        let window = Int(0.3 * rate) ..< Int(0.8 * rate)
        let played = window.map { output[0][applyAt + $0] }
        let maxShift = 2048
        let reference = (-maxShift ..< window.count + maxShift).map {
            piecewiseLinear(reappliedEvents, frame: window.lowerBound + $0, rate: rate)
        }
        let lead = bestShift(played, maxShift: maxShift) { reference[$0 + maxShift] }

        reportMeasure("reapply anchor", "fade leads the playhead by \(lead) frames at block 512")
        #expect(abs(lead) <= 1, "fade leads the playhead by \(lead) frames")
    }
}

// MARK: - Reference evaluation

/// The value a list of linear events reaches at `frame`, as the DSP ramps them: each event ramps
/// from wherever the previous one had got to. Times become frames by truncation, as the render
/// observer converts them.
func piecewiseLinear(_ events: [AutomationEvent], initial: Float = 0, frame: Int, rate: Double) -> Float {
    var from = initial
    var current: (start: Int, duration: Int, target: Float)?

    func value(startingAt start: Float, at f: Int) -> Float {
        guard let current else { return start }
        let elapsed = f - current.start
        guard current.duration > 0, elapsed < current.duration else { return current.target }
        return start + (current.target - start) * Float(elapsed) / Float(current.duration)
    }

    for event in events.sorted(by: { $0.startTime < $1.startTime }) {
        let start = Int((Double(event.startTime) * rate).rounded(.down))
        guard start <= frame else { break }
        from = value(startingAt: from, at: start)
        current = (start, Int(Double(event.rampDuration) * rate), event.targetValue)
    }

    return value(startingAt: from, at: frame)
}

/// The shift `d` for which `measured[k]` best matches `reference(k + d)`: how many frames ahead of
/// the reference the measured curve runs.
func bestShift(_ measured: [Float], maxShift: Int, reference: (Int) -> Float) -> Int {
    var best = (shift: 0, error: Float.infinity)
    let stride = 16
    for shift in -maxShift ... maxShift {
        var error: Float = 0
        for k in Swift.stride(from: 0, to: measured.count, by: stride) {
            error += abs(measured[k] - reference(k + shift))
        }
        if error < best.error { best = (shift, error) }
    }
    return best.shift
}
