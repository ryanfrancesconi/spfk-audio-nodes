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

    /// `ramp(to:duration:delay:)` starts `delay` after the next render and lasts `duration`.
    @Test(arguments: rampCases)
    func rampStartsAfterItsDelay(blockSize: AVAudioFrameCount, delay: Float) async throws {
        let duration: Float = 0.25
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: blockSize,
            started: { [rate] in
                $0.$leftGain.ramp(to: 0, duration: duration, delay: delay, sampleRate: Float(rate))
                $0.$rightGain.ramp(to: 0, duration: duration, delay: delay, sampleRate: Float(rate))
            }
        )

        let start = firstFrame(output[0], where: { $0 < 0.99999 })
        let end = firstFrame(output[0], where: { $0 == 0 })
        let expectedStart = Int(delay * Float(rate))
        let expectedEnd = expectedStart + Int(duration * Float(rate))

        reportMeasure("ramp block=\(blockSize) delay=\(delay)", "starts \(start) (expected \(expectedStart)), ends \(end) (expected \(expectedEnd))")

        withKnownIssue("a delay over 4096 frames is clamped to 4096") {
            #expect(abs(start - expectedStart) <= 1, "starts at \(start), expected \(expectedStart)")
            #expect(abs(end - expectedEnd) <= 1, "ends at \(end), expected \(expectedEnd)")
        } when: {
            expectedStart > 4096
        }
    }

    /// `ramp(from:to:duration:)` reaches `from` first, then ramps to `to` over `duration`.
    @Test(arguments: [512, 4096] as [AVAudioFrameCount])
    func rampFromStartsAtItsSource(blockSize: AVAudioFrameCount) async throws {
        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: blockSize,
            started: { $0.ramp(from: 0.2, to: 0.8, duration: 0.25) }
        )

        let primer = Int(ParameterAutomationTiming.primerRampDuration * Float(rate))
        let reached = output[0][primer...].firstIndex(where: { $0 >= 0.79999 }) ?? -1
        reportMeasure(
            "ramp(from:) block=\(blockSize)",
            String(format: "frame 0 %.5f; at primer end (%d) %.5f; reaches 0.8 at %d (expected %d)",
                   output[0][0], primer, output[0][primer], reached, primer + Int(0.25 * rate))
        )

        #expect(abs(output[0][primer] - 0.2) < 1e-3, "at the primer's end the gain is \(output[0][primer])")
        #expect(abs(reached - (primer + Int(0.25 * rate))) <= 1, "reaches 0.8 at \(reached)")
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

    /// Values written between `beginTouch` and `endTouch` reach the recording callback in order,
    /// each with the time it was written.
    @MainActor
    @Test(.disabled(Self.recordingTraps))
    func recordingDeliversWritesInOrderWithTheirTimes() async throws {
        let channelGain = try await ChannelGain()
        let parameter = channelGain.$leftGain
        let written: [AUValue] = [0.1, 0.3, 0.5, 0.7, 0.9, 0.6, 0.4, 0.2]
        var received: [AUParameterAutomationEvent] = []

        parameter.recordAutomation { received.append($0) }
        parameter.beginTouch(value: 0.05)
        for value in written {
            channelGain.leftGain = value
            try await wait(sec: 0.02)
        }
        parameter.endTouch(value: 0.15)
        try await wait(for: received.count >= written.count + 2, timeout: 2)

        let values = received.map(\.value)
        let hostTimes = received.map(\.hostTime)
        let kinds = received.map(\.eventType.rawValue)
        reportMeasure("recording", "\(received.count) events, values \(values), kinds \(kinds), host times \(hostTimes)")

        #expect(values == [0.05] + written + [0.15], "received \(values)")

        #expect(hostTimes.allSatisfy { $0 != 0 }, "host times \(hostTimes)")
        #expect(zip(hostTimes, hostTimes.dropFirst()).allSatisfy { $0 <= $1 }, "host times out of order")
    }

    /// Measured 2026-10-24 against `spfk-audio-nodes` 4523986: the observer closure inherits the
    /// method's `@MainActor` isolation, AudioToolbox calls it from a dispatch worker, and the runtime's
    /// isolation check traps on the first event.
    static let recordingTraps: Comment = "recordAutomation traps on its first event, which arrives off the main actor"

    /// A second `recordAutomation` replaces the first rather than leaving it running.
    @MainActor
    @Test(.disabled(Self.recordingTraps))
    func recordingTwiceReplacesTheFirstObserver() async throws {
        let channelGain = try await ChannelGain()
        let parameter = channelGain.$leftGain
        var first = 0, second = 0

        parameter.recordAutomation { _ in first += 1 }
        parameter.recordAutomation { _ in second += 1 }
        channelGain.leftGain = 0.4
        try await wait(for: second > 0, timeout: 2)
        try await wait(sec: 0.1)

        parameter.stopRecording()
        channelGain.leftGain = 0.6
        try await wait(sec: 0.1)

        reportMeasure("record twice", "first observer fired \(first) times, second \(second)")

        #expect(first == 0, "the replaced observer fired \(first) times")
        #expect(second == 1, "the live observer fired \(second) times")
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

    /// Recorded points merged with `replace(range:withPoints:)` play back at their times.
    @Test func replacedRangePlaysTheRecordedPoints() async throws {
        let recorded: [(Float, AUValue)] = [(0.2, 0.3), (0.4, 0.8), (0.6, 0.5), (0.8, 0.9)]
        let base = AutomationCurve(points: [ParameterAutomationPoint(targetValue: 1, startTime: 0, rampDuration: 0)])
        let curve = base.replace(range: 0.1 ... 0.9, withPoints: recorded)

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: { try $0.automate(events: curve.events, startTime: GainRenderHarness.renderStart) }
        )

        let settle = Int(ParameterAutomationTiming.recordedPointRampDuration * Float(rate))
        let played = recorded.map { output[0][Int($0.0 * Float(rate)) + settle + 1] }
        reportMeasure("replace", "played \(played) for \(recorded.map(\.1))")

        #expect(zip(played, recorded).allSatisfy { abs($0 - $1.1) < 1e-4 }, "played \(played)")
    }

    // MARK: - Several parameters and observers

    /// Automating two parameters of one node leaves each on its own curve.
    @Test func parametersAutomateIndependently() async throws {
        let left = [AutomationEvent(targetValue: 0, startTime: 0.25, rampDuration: 0.25)]
        let right = [AutomationEvent(targetValue: 0.5, startTime: 0.1, rampDuration: 0)]

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: {
                try $0.$leftGain.automate(events: left, startTime: GainRenderHarness.renderStart)
                try $0.$rightGain.automate(events: right, startTime: GainRenderHarness.renderStart)
            }
        )

        let frames = 0 ..< output[0].count
        let leftError = CurveError(output[0], frames.map { piecewiseLinear(left, initial: 1, frame: $0, rate: rate) })
        let rightError = CurveError(output[1], frames.map { piecewiseLinear(right, initial: 1, frame: $0, rate: rate) })
        reportMeasure("independent parameters", "left \(leftError); right \(rightError)")

        #expect(leftError.maxAbs <= 1e-5, "left \(leftError)")
        #expect(rightError.maxAbs <= 1e-5, "right \(rightError)")
    }

    /// Two observers on one parameter, overlapping in time. Reference for R7: nothing specifies this.
    @Test(.tags(.development)) func overlappingObserversReference() async throws {
        let ramp = [AutomationEvent(targetValue: 0, startTime: 0.1, rampDuration: 0.5)]
        let step = [AutomationEvent(targetValue: 0.5, startTime: 0.3, rampDuration: 0)]

        let output = try await GainRenderHarness.render(
            GainRenderHarness.makeDC(seconds: 1), blockSize: 512,
            started: {
                try $0.$leftGain.automate(events: ramp, startTime: GainRenderHarness.renderStart)
                try $0.$leftGain.addLoopObserver(events: step, startTime: GainRenderHarness.renderStart)
            }
        )

        let at = { (t: Double) in output[0][Int(t * self.rate)] }
        reportMeasure(
            "overlapping observers",
            String(format: "0.2 s %.4f (ramp alone %.4f); 0.35 s %.4f; 0.7 s %.4f (ramp alone 0)",
                   at(0.2), piecewiseLinear(ramp, initial: 1, frame: Int(0.2 * self.rate), rate: self.rate), at(0.35), at(0.7))
        )
    }
}
