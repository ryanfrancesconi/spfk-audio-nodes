// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import os
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// The automation API no client in this workspace calls — ramps, track automation, recording and
/// several observers — rendered offline.
@Suite(.tags(.engine, .automation), .serialized)
final class AutomationAPIRenderTests: TestCaseModel {
    private let rate = GainRenderHarness.sampleRate

    private func firstFrame(_ channel: [Float], where predicate: (Float) -> Bool) -> Int {
        channel.firstIndex(where: predicate) ?? -1
    }

    // MARK: - Ramps

    static let rampCases: [(blockSize: AVAudioFrameCount, delay: Float)] =
        [512, 4096].flatMap { block in [0.05, 0.2].map { (AVAudioFrameCount(block), Float($0)) } }

    /// `ramp(_:to:duration:delay:)` starts `delay` after the next render and lasts `duration`.
    @Test(arguments: rampCases)
    func rampStartsAfterItsDelay(blockSize: AVAudioFrameCount, delay: Float) async throws {
        let duration: Float = 0.25
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: blockSize,
            started: {
                try $0.automation.ramp(GainRenderHarness.gainAddresses, to: 0, duration: TimeInterval(duration), delay: TimeInterval(delay))
            }
        )

        let start = firstFrame(output[0], where: { $0 < 0.99999 })
        let end = firstFrame(output[0], where: { $0 == 0 })
        let expectedStart = Int(delay * Float(rate))
        let expectedEnd = expectedStart + Int(duration * Float(rate))

        reportMeasure("ramp block=\(blockSize) delay=\(delay)", "starts \(start) (expected \(expectedStart)), ends \(end) (expected \(expectedEnd))")

        #expect(abs(start - expectedStart) <= 1, "starts at \(start), expected \(expectedStart)")
        #expect(abs(end - expectedEnd) <= 1, "ends at \(end), expected \(expectedEnd)")
    }

    /// `ramp(_:from:to:duration:)` opens on `from` and reaches `to` after `duration`.
    @Test(arguments: [512, 4096] as [AVAudioFrameCount])
    func rampFromStartsAtItsSource(blockSize: AVAudioFrameCount) async throws {
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: blockSize,
            started: { try $0.automation.ramp(GainRenderHarness.gainAddresses, from: 0.2, to: 0.8, duration: 0.25) }
        )

        let reached = output[0].firstIndex(where: { $0 >= 0.79999 }) ?? -1
        reportMeasure(
            "ramp(from:) block=\(blockSize)",
            String(format: "frame 0 %.5f; reaches 0.8 at %d (expected %d)", output[0][0], reached, Int(0.25 * rate))
        )

        #expect(abs(output[0][0] - 0.2) < 1e-6, "opens at \(output[0][0])")
        #expect(abs(reached - Int(0.25 * rate)) <= 1, "reaches 0.8 at \(reached)")
    }

    // MARK: - Track automation

    /// UI points through `ParameterCurve(points:taper:)` play the curve they describe.
    @Test func trackAutomationPlaysItsCurve() async throws {
        let times: [TimeInterval] = [0.1, 0.6, 1.1, 1.6, 2.1]
        let gains: [AUValue] = [0.2, 1.0, 0.3, 0.9, 0.1]
        let taper = AudioTaper.default
        let points = zip(times, gains).map { AutomationPoint(time: $0, gain: $1) }
        let curve = try ParameterCurve(points: points, taper: taper)

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 2.3), blockSize: 512,
            started: { try GainRenderHarness.publish(curve, on: $0, combine: .replace) }
        )

        // Each segment ramps from the previous point's gain with the taper, inverted going down.
        func exact(at t: Double) -> Float {
            guard t >= times[0] else { return gains[0] }
            guard let i = times.firstIndex(where: { $0 > t }) else { return gains[gains.count - 1] }
            let from = gains[i - 1], to = gains[i]
            let shape = from > to ? AudioTaper(value: taper.inverseValue, skew: taper.skew) : taper
            let x = (t - times[i - 1]) / (times[i] - times[i - 1])
            return from + (to - from) * Float(shape.gain(at: x))
        }

        let range = 0 ..< output[0].count
        let error = CurveError(output[0][range], range.map { exact(at: Double($0) / rate) }[...])
        reportMeasure("track automation", "\(error)")

        #expect(error.maxAbs <= 1e-6, "\(error)")
    }

    // MARK: - Recording

    /// Values written between `beginTouch` and `endTouch` are recorded in order, each with the time
    /// it was written.
    @Test func recordingDeliversWritesInOrderWithTheirTimes() async throws {
        let channelGain = try await ChannelGain()
        let parameter = channelGain.$leftGain
        let written: [AUValue] = [0.1, 0.3, 0.5, 0.7, 0.9, 0.6, 0.4, 0.2]
        let recorder = try AutomationRecorder(parameter)

        recorder.start()
        parameter.beginTouch(value: 0.05)
        for value in written {
            channelGain.leftGain = value
            try await wait(sec: 0.01)
        }
        parameter.endTouch(value: 0.15)
        try await wait(for: recorder.recorded.count >= written.count + 2, timeout: 2)
        recorder.stop()

        let received = recorder.recorded
        let values = received.map(\.value)
        let hostTimes = received.map(\.hostTime)
        reportMeasure("recording", "\(received.count) events, values \(values), host times \(hostTimes)")

        #expect(values == [0.05] + written + [0.15], "received \(values)")
        #expect(received.first?.eventType == .touch)
        #expect(received.last?.eventType == .release)
        #expect(hostTimes.allSatisfy { $0 != 0 }, "host times \(hostTimes)")
        #expect(zip(hostTimes, hostTimes.dropFirst()).allSatisfy { $0 <= $1 }, "host times out of order")
    }

    /// A second `start` replaces the first recording, and `stop` ends it.
    @Test func recordingTwiceReplacesTheFirst() async throws {
        let channelGain = try await ChannelGain()
        let recorder = try AutomationRecorder(channelGain.$leftGain)

        recorder.start()
        channelGain.leftGain = 0.4
        try await wait(for: recorder.recorded.count == 1, timeout: 2)

        recorder.start()
        channelGain.leftGain = 0.6
        try await wait(for: recorder.recorded.count == 1 && recorder.recorded.first?.value == 0.6, timeout: 2)
        try await wait(sec: 0.1)
        #expect(recorder.recorded.map(\.value) == [0.6], "one observer, the second recording")

        recorder.stop()
        channelGain.leftGain = 0.8
        try await wait(sec: 0.1)
        #expect(recorder.recorded.map(\.value) == [0.6], "stopped")
        #expect(!recorder.isRecording)
    }

    /// A recording merged into a curve plays back where it was written, and the curve around it is
    /// unchanged.
    @Test func mergedRecordingPlaysWhereItWasWritten() async throws {
        let channelGain = try await ChannelGain()
        let recorder = try AutomationRecorder(channelGain.$leftGain)
        let written: [AUValue] = [0.2, 0.6, 0.4]

        recorder.start()
        for value in written {
            channelGain.leftGain = value
            try await wait(sec: 0.02)
        }
        try await wait(for: recorder.recorded.count == written.count, timeout: 2)
        recorder.stop()

        // Each write at source position 0.25, 0.5, 0.75 in the order written.
        let positions = Dictionary(uniqueKeysWithValues: recorder.recorded.enumerated().map { ($1.hostTime, 0.25 * Double($0 + 1)) })
        let base = try ParameterCurve([CurveSegment(start: 0, end: 1, startValue: 1, endValue: 0)])
        let curve = try recorder.merged(into: base) { positions[$0] }

        #expect(abs(curve.value(at: 0.1) - base.value(at: 0.1)) < 1e-6)
        #expect(curve.value(at: 0.25) == 0.2)
        #expect(abs(curve.value(at: 0.375) - 0.4) < 1e-6)
        #expect(curve.value(at: 0.5) == 0.6)
        // The span replaced is half-open: the recording ramps to its last value, and the curve it
        // replaced resumes on that frame.
        #expect(abs(curve.value(at: 0.74) - 0.408) < 1e-6)
        #expect(curve.value(at: 0.75) == base.value(at: 0.75))
        #expect(abs(curve.value(at: 0.9) - base.value(at: 0.9)) < 1e-6)

        #expect(throws: AutomationRecorder.MergeError.unmapped) { try recorder.merged(into: base) { _ in nil } }
        let reversing = Dictionary(uniqueKeysWithValues: recorder.recorded.enumerated().map { ($1.hostTime, [0.5, 0.9, 0.1][$0]) })
        #expect(throws: AutomationRecorder.MergeError.notMonotonic) { try recorder.merged(into: base) { reversing[$0] } }
    }

    /// What AudioToolbox itself delivers to an automation observer for touch, writes and release:
    /// the order, the event types and the host times. Reference for R8.
    @Test(.tags(.development)) func automationObserverDeliveryReference() async throws {
        let channelGain = try await ChannelGain()
        let parameter = try #require(channelGain.$leftGain.parameter)
        let received = OSAllocatedUnfairLock(initialState: [AUParameterAutomationEvent]())

        let token = parameter.token(byAddingParameterAutomationObserver: { count, events in
            let batch = (0 ..< count).map { events[$0] }
            received.withLock { $0.append(contentsOf: batch) }
        })
        defer { parameter.removeParameterObserver(token) }

        let start = mach_absolute_time()
        channelGain.$leftGain.beginTouch(value: 0.05)
        for value: AUValue in [0.1, 0.3, 0.5, 0.7] {
            channelGain.leftGain = value
            try await wait(sec: 0.02)
        }
        channelGain.$leftGain.endTouch(value: 0.15)
        try await wait(sec: 0.3)

        let events = received.withLock { $0 }
        let summary = events.map { event in
            let ms = event.hostTime == 0 ? "0" : String(format: "%.1f ms", AVAudioTime.seconds(forHostTime: event.hostTime &- start) * 1000)
            return "\(event.eventType.rawValue):\(event.value)@\(ms)"
        }
        reportMeasure("automation observer delivery", summary.joined(separator: ", "))
    }

    /// Recorded points merged with `replacing(range:with:)` play back at their times.
    @Test func replacedRangePlaysTheRecordedPoints() async throws {
        let recorded: [(Double, AUValue)] = [(0.2, 0.3), (0.4, 0.8), (0.6, 0.5), (0.8, 0.9)]
        let steps = recorded.map { CurveSegment(start: $0.0, end: $0.0, startValue: $0.1, endValue: $0.1) }
        let curve = try ParameterCurve(constant: 1).replacing(range: 0.1 ..< 0.9, with: steps)

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: { try GainRenderHarness.publish(curve, on: $0, combine: .replace) }
        )

        let played = recorded.map { output[0][Int($0.0 * rate) + 1] }
        reportMeasure("replace", "played \(played) for \(recorded.map(\.1))")

        #expect(zip(played, recorded).allSatisfy { abs($0 - $1.1) < 1e-4 }, "played \(played)")
    }

    // MARK: - Several parameters and observers

    /// Automating two parameters of one node leaves each on its own curve.
    @Test func parametersAutomateIndependently() async throws {
        let left = try ParameterCurve([CurveSegment(start: 0.25, end: 0.5, startValue: 1, endValue: 0)])
        let right = try ParameterCurve([CurveSegment(start: 0.1, end: 0.1, startValue: 1, endValue: 0.5)])

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: {
                try $0.automation.publish(
                    [ChannelGainParameter.leftGain.rawValue: left, ChannelGainParameter.rightGain.rawValue: right],
                    mapping: TimelineMapping(renderAnchor: .sample(0), sourceAnchor: 0, renderSampleRate: GainRenderHarness.sampleRate)
                )
            }
        )

        let frames = 0 ..< output[0].count
        let leftError = CurveError(output[0], frames.map { left.value(at: Double($0) / rate) })
        let rightError = CurveError(output[1], frames.map { right.value(at: Double($0) / rate) })
        reportMeasure("independent parameters", "left \(leftError); right \(rightError)")

        #expect(leftError.maxAbs <= 1e-5, "left \(leftError)")
        #expect(rightError.maxAbs <= 1e-5, "right \(rightError)")
    }

    /// A second publish on a parameter replaces the first: one automation per parameter, by
    /// construction.
    @Test func secondPublishReplacesTheFirst() async throws {
        let ramp = try ParameterCurve([CurveSegment(start: 0.1, end: 0.6, startValue: 1, endValue: 0)])
        let step = try ParameterCurve(constant: 0.5)
        let replaceAt = Int(0.3 * rate) / 512 * 512

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: { try GainRenderHarness.publish(ramp, on: $0) },
            beforeBlock: { rendered, channelGain in
                if rendered == replaceAt { try GainRenderHarness.publish(step, on: channelGain) }
            }
        )

        let at = { (t: Double) in output[0][Int(t * self.rate)] }
        #expect(abs(at(0.2) - ramp.value(at: 0.2)) < 1e-6)
        #expect(abs(at(0.35) - 0.5) < 1e-6)
        #expect(abs(at(0.7) - 0.5) < 1e-6, "the first curve does not resume")
    }
}
