// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import Foundation
import SPFKAudioBase
import SPFKBase
import Testing

@testable import SPFKAudioNodes
@testable import SPFKAudioNodesC

@Suite(.tags(.automation))
struct AutomationCurveTests {
    // MARK: - evalRamp

    // Linear taper (value=1, skew=0) must be an exact straight line: gain == x at every point.
    @Test func evalRampLinearIsLinear() {
        let point = ParameterAutomationPoint(
            targetValue: 1.0, startTime: 0, rampDuration: 2.0,
            rampTaper: AudioTaper.linear.value, rampSkew: AudioTaper.linear.skew
        )
        for step in 1 ... 9 {
            let x = Float(step) / 10.0
            let result = AutomationCurve.evalRamp(start: 0, point: point, time: x * 2.0, endTime: 2.0)
            #expect(abs(result - x) < 1e-5, "Linear taper: gain should equal x at x=\(x)")
        }
    }

    // Default taper (value=3, skew=1/3) at x=0.5: (2/3)*0.5³ + (1/3)*(1-0.5^(1/3)) ≈ 0.152.
    // Anchors the blend formula — any change to evalRamp that alters this value is a regression.
    @Test func evalRampDefaultTaperMidpoint() {
        let point = ParameterAutomationPoint(
            targetValue: 1.0, startTime: 0, rampDuration: 2.0,
            rampTaper: AudioTaper.default.value, rampSkew: AudioTaper.default.skew
        )
        let result = AutomationCurve.evalRamp(start: 0, point: point, time: 1.0, endTime: 2.0)
        #expect(abs(result - 0.152) < 0.001)
    }

    // With taper.value used for both fade directions, gainIn(x) + gainOut(x) == 1.0 for all x.
    // This algebraic identity holds when fade-out uses taper.value — it breaks if inverseValue is used.
    @Test func evalRampFadeInFadeOutSumToOne() {
        let taper = AudioTaper.default
        let fadeInPoint = ParameterAutomationPoint(
            targetValue: 1.0, startTime: 0, rampDuration: 2.0,
            rampTaper: taper.value, rampSkew: taper.skew
        )
        let fadeOutPoint = ParameterAutomationPoint(
            targetValue: 0.0, startTime: 0, rampDuration: 2.0,
            rampTaper: taper.value, rampSkew: taper.skew
        )
        for step in 1 ... 9 {
            let time = Float(step) / 10.0 * 2.0
            let gainIn = AutomationCurve.evalRamp(start: 0, point: fadeInPoint, time: time, endTime: 2.0)
            let gainOut = AutomationCurve.evalRamp(start: 1, point: fadeOutPoint, time: time, endTime: 2.0)
            #expect(abs(gainIn + gainOut - 1.0) < 1e-5, "Fade-in + fade-out must sum to 1.0 at t=\(time)")
        }
    }

    // MARK: - Fade curve invariants

    @Test func fadeInIsMonotonicallyIncreasing() throws {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 3.0
        let value = desc.fadeInCurve()
        let curve = try #require(value)
        let values = curve.events.map(\.targetValue)
        for i in 1 ..< values.count {
            #expect(values[i] >= values[i - 1], "Fade-in event \(i) must not decrease")
        }
    }

    @Test func fadeInBoundaryValues() throws {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 3.0

        let value = desc.fadeInCurve()
        let curve = try #require(value)
        #expect(curve.events.first?.targetValue == RegionFadeDescription.minimumGain)
        #expect(curve.events.last?.targetValue == desc.maximumGain)
    }

    @Test func fadeOutIsMonotonicallyDecreasing() throws {
        var desc = RegionFadeDescription()
        desc.fade.outTime = 3.0
        desc.segmentDuration = 3.0
        let value = desc.fadeOutCurve()
        let curve = try #require(value)
        let values = curve.events.map(\.targetValue)
        for i in 1 ..< values.count {
            #expect(values[i] <= values[i - 1], "Fade-out event \(i) must not increase")
        }
    }

    @Test func fadeOutEndsAtZero() throws {
        var desc = RegionFadeDescription()
        desc.fade.outTime = 3.0
        desc.segmentDuration = 3.0

        let value = desc.fadeOutCurve()
        let curve = try #require(value)
        #expect(curve.events.last?.targetValue == RegionFadeDescription.minimumGain)
    }

    // MARK: - AutomationCurve replace

    @Test func replaceAutomationBasic() {
        let curve = AutomationCurve(points: [
            ParameterAutomationPoint(targetValue: 440, startTime: 0, rampDuration: 0.1),
            ParameterAutomationPoint(targetValue: 880, startTime: 1, rampDuration: 0.1),
            ParameterAutomationPoint(targetValue: 440, startTime: 2, rampDuration: 0.1),
        ])

        let events: [(Float, AUValue)] = [(0.5, 100), (1.5, 200)]

        let newCurve = curve.replace(range: 0.25 ... 1.75, withPoints: events)

        let expected = [
            ParameterAutomationPoint(targetValue: 440, startTime: 0.0, rampDuration: 0.1),
            ParameterAutomationPoint(targetValue: 100, startTime: 0.5, rampDuration: 0.01),
            ParameterAutomationPoint(targetValue: 200, startTime: 1.5, rampDuration: 0.01),
            ParameterAutomationPoint(targetValue: 440, startTime: 2.0, rampDuration: 0.1),
        ]

        #expect(newCurve.points == expected)
    }

    @Test func replaceAutomationErase() {
        let curve = AutomationCurve(points: [
            ParameterAutomationPoint(targetValue: 440, startTime: 0, rampDuration: 0.1),
            ParameterAutomationPoint(targetValue: 880, startTime: 1, rampDuration: 0.1),
            ParameterAutomationPoint(targetValue: 440, startTime: 2, rampDuration: 0.1),
        ])

        let events: [(Float, AUValue)] = []

        let newCurve = curve.replace(range: 0 ... 2, withPoints: events)

        #expect(newCurve.points == [])
    }

    @Test func replaceAutomationAdd() {
        let curve = AutomationCurve(points: [])

        let events: [(Float, AUValue)] = [(0.5, 100), (1.5, 200)]

        let newCurve = curve.replace(range: 0 ... 2, withPoints: events)

        let expected = [
            ParameterAutomationPoint(targetValue: 100, startTime: 0.5, rampDuration: 0.01),
            ParameterAutomationPoint(targetValue: 200, startTime: 1.5, rampDuration: 0.01),
        ]

        #expect(newCurve.points == expected)
    }
}
