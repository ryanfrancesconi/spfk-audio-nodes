// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import Foundation
import SPFKAudioBase
import SPFKBase
import Testing

@testable import SPFKAudioNodes
@testable import SPFKAudioNodesC

@Suite(.tags(.automation))
struct FadeDescriptionTests {
    // MARK: - in

    @Test func fadeInReturnsNilWhenZeroTime() {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 0
        #expect(desc.fadeInCurve() == nil)
    }

    @Test func fadeInTruncatingLastPointDuration() throws {
        var desc = RegionFadeDescription()
        desc.maximumGain = 1
        desc.stepResolution = 0.2

        // should be a value that doesn't divide by stepResolution
        desc.fade.inTime = 4.305577
        desc.fade.inTaper = .default
        desc.stepResolution = 0.2

        let curve = desc.fadeInCurve()
        let events = try #require(curve?.events)

        let firstPoint = try #require(events.first)
        let lastPoint = try #require(events.last)

        Log.debug(firstPoint, lastPoint)

        #expect(events.count == 23)
        #expect(firstPoint == AutomationEvent(targetValue: 0.0, startTime: -0.1, rampDuration: 0.0))
        #expect(lastPoint == AutomationEvent(targetValue: 1.0, startTime: 4.2000003, rampDuration: 0.105576515))
    }

    @Test func fadeInLinearOneSecond() throws {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 1
        desc.fade.inTaper = .linear

        let curve = desc.fadeInCurve()
        let events = try #require(curve?.events)

        #expect(events.count == 2)

        Log.debug(events)

        let expectedResult = [
            AutomationEvent(targetValue: 0.0, startTime: -0.1, rampDuration: 0.0),
            AutomationEvent(targetValue: 1.0, startTime: 0.0, rampDuration: 1.0),
        ]

        #expect(events.count == expectedResult.count)
        #expect(events == expectedResult)
        #expect(events == desc.fadeInCache?.events)
    }

    @Test func fadeInTaperOneSecond() throws {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 1
        desc.fade.inTaper = .default

        let curve = desc.fadeInCurve()
        let events = try #require(curve?.events)

        Log.debug(events)

        let expectedResult = [
            AutomationEvent(targetValue: 0.0, startTime: -0.1, rampDuration: 0.0),
            AutomationEvent(targetValue: 0.029227404, startTime: 0.0, rampDuration: 0.2),
            AutomationEvent(targetValue: 0.09485577, startTime: 0.2, rampDuration: 0.2),
            AutomationEvent(targetValue: 0.23173125, startTime: 0.4, rampDuration: 0.2),
            AutomationEvent(targetValue: 0.47973216, startTime: 0.6, rampDuration: 0.2),
            AutomationEvent(targetValue: 1.0, startTime: 0.8, rampDuration: 0.19999999),
        ]

        #expect(events.count == expectedResult.count)
        #expect(events == expectedResult)
        #expect(events == desc.fadeInCache?.events)
    }

    @Test func fadeInReverseTaperOneSecond() throws {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 1
        desc.fade.inTaper = .reverseAudio

        let curve = desc.fadeInCurve()
        let events = try #require(curve?.events)

        Log.debug(events)

        let expectedResult = [
            AutomationEvent(targetValue: 0.0, startTime: -0.1, rampDuration: 0.0),
            AutomationEvent(targetValue: 0.55253565, startTime: 0.0, rampDuration: 0.2),
            AutomationEvent(targetValue: 0.7525375, startTime: 0.2, rampDuration: 0.2),
            AutomationEvent(targetValue: 0.87428844, startTime: 0.4, rampDuration: 0.2),
            AutomationEvent(targetValue: 0.94954515, startTime: 0.6, rampDuration: 0.2),
            AutomationEvent(targetValue: 1.0, startTime: 0.8, rampDuration: 0.19999999),
        ]

        #expect(events.count == expectedResult.count)
        #expect(events == expectedResult)
        #expect(events == desc.fadeInCache?.events)
    }

    // MARK: - out

    @Test func fadeOutReturnsNilWhenZeroTime() {
        var desc = RegionFadeDescription()
        desc.fade.outTime = 0
        desc.segmentDuration = 1
        #expect(desc.fadeOutCurve() == nil)
    }

    @Test func fadeOutTaperOneSecond() throws {
        var desc = RegionFadeDescription()
        desc.fade.outTime = 1
        desc.segmentDuration = 1
        desc.stepResolution = 0.2
        desc.fade.outTaper = .default

        let curve = desc.fadeOutCurve()
        let events = try #require(curve?.events)

        // 1 lead-in + ceil(1.0 / 0.2) = 5 ramp events
        #expect(events.count == 6)
        #expect(events.first?.targetValue == desc.maximumGain)
        #expect(events.last?.targetValue == RegionFadeDescription.minimumGain)
        #expect(events == desc.fadeOutCache?.events)

        let values = events.map(\.targetValue)
        for i in 1 ..< values.count {
            #expect(values[i] <= values[i - 1], "Fade-out event \(i) must not increase")
        }
    }

    // Tests that crop() correctly trims events when playback begins inside the fade curve.
    @Test func fadeOutStartingInsideCurve() throws {
        var desc = RegionFadeDescription()
        desc.fade.outTime = 1
        desc.segmentDuration = 0.8   // starts 0.2s into a 1s fade
        desc.fade.outTaper = .default

        let curve = desc.fadeOutCurve()
        let events = try #require(curve?.events)

        #expect(events == desc.fadeOutCache?.events)

        // Cropped curve must have fewer events than the full 1s fade.
        var fullDesc = RegionFadeDescription()
        fullDesc.fade.outTime = 1
        fullDesc.segmentDuration = 1
        fullDesc.fade.outTaper = .default
        let fullCount = fullDesc.fadeOutCurve()?.events.count ?? 0
        #expect(events.count < fullCount)

        // First event represents a mid-curve position: gain must be strictly between 0 and max.
        let firstGain = try #require(events.first?.targetValue)
        #expect(firstGain > RegionFadeDescription.minimumGain)
        #expect(firstGain < desc.maximumGain)

        #expect(events.last?.targetValue == RegionFadeDescription.minimumGain)

        let values = events.map(\.targetValue)
        for i in 1 ..< values.count {
            #expect(values[i] <= values[i - 1], "Cropped fade-out event \(i) must not increase")
        }
    }

    // MARK: - gainAt

    @Test func gainAtReturnsMaximumGainOutsideFadeZones() {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 1
        desc.fade.outTime = 1
        desc.fade.inTaper = .default
        desc.fade.outTaper = .default
        // Middle of a 10s file: no fade zone active
        desc.segmentDuration = 10 - 5
        #expect(desc.gainAt(playbackOffset: 5) == desc.maximumGain)
    }

    @Test func gainAtFadeInLinearBoundaries() {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 2
        desc.fade.inTaper = .linear
        let duration = 10.0

        desc.segmentDuration = duration
        #expect(desc.gainAt(playbackOffset: 0).isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))

        // At end of fade-in (== inTime), condition is `< inTime` so we fall through to maximumGain
        desc.segmentDuration = duration - 2
        #expect(desc.gainAt(playbackOffset: 2) == desc.maximumGain)
    }

    @Test func gainAtFadeInLinearMidpointIsHalf() {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 2
        desc.fade.inTaper = .linear
        desc.segmentDuration = 10 - 1
        #expect(desc.gainAt(playbackOffset: 1).isApproximatelyEqual(to: 0.5, absoluteTolerance: 0.001))
    }

    @Test func gainAtFadeOutLinearMidpointIsHalf() {
        var desc = RegionFadeDescription()
        desc.fade.outTime = 2
        desc.fade.outTaper = .linear
        let duration = 10.0

        desc.segmentDuration = duration - 9
        #expect(desc.gainAt(playbackOffset: 9).isApproximatelyEqual(to: 0.5, absoluteTolerance: 0.001))

        desc.segmentDuration = duration - 10
        #expect(desc.gainAt(playbackOffset: 10).isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
    }

    @Test func gainAtFadeInMatchesAudioTaperFormula() {
        // RegionFadeDescription.gainAt uses its own inline math; cross-check it against
        // AudioTaper.gainAt(t:) so the two implementations can't silently diverge.
        for taper in AudioTaper.presets {
            var desc = RegionFadeDescription()
            desc.fade.inTime = 1
            desc.fade.inTaper = taper
            desc.segmentDuration = 2

            for step in 0 ... 10 {
                let t = Double(step) / 10.0
                // gainAt uses `< inTime`, so clamp to just below boundary
                let offset = t < 1.0 ? t : 0.999
                let expected = Float(taper.gainAt(t: offset))
                let actual = desc.gainAt(playbackOffset: offset)
                #expect(
                    actual.isApproximatelyEqual(to: expected, absoluteTolerance: 0.001),
                    "taper \(taper), t=\(t): got \(actual), expected \(expected)"
                )
            }
        }
    }

    @Test func gainAtFadeInIsMonotonicallyIncreasing() {
        for taper in AudioTaper.presets {
            var desc = RegionFadeDescription()
            desc.fade.inTime = 1
            desc.fade.inTaper = taper
            desc.segmentDuration = 2
            var prev: AUValue = -1
            for step in 0 ... 9 {
                let gain = desc.gainAt(playbackOffset: Double(step) / 10.0)
                #expect(gain >= prev, "taper \(taper) not monotone at step \(step)")
                prev = gain
            }
        }
    }

    @Test func gainAtFadeOutIsMonotonicallyDecreasing() {
        for taper in AudioTaper.presets {
            var desc = RegionFadeDescription()
            desc.fade.outTime = 1
            desc.fade.outTaper = taper
            let duration = 2.0
            var prev: AUValue = 2
            // Sample across the 1s fade-out window at the end of a 2s file
            for step in 0 ... 10 {
                let offset = 1.0 + Double(step) / 10.0  // 1.0 ... 2.0
                desc.segmentDuration = duration - offset
                let gain = desc.gainAt(playbackOffset: offset)
                #expect(gain <= prev, "taper \(taper) not monotone decreasing at offset \(offset)")
                prev = gain
            }
        }
    }

    // MARK: - cache

    @Test func fadeCache() throws {
        var desc = RegionFadeDescription()
        desc.fade.inTime = 1
        desc.fade.outTime = 1
        desc.segmentDuration = 2
        desc.fade.inTaper = .default
        desc.fade.outTaper = .default

        let curveIn = desc.fadeInCurve()
        let curveOut = desc.fadeOutCurve()

        #expect(desc.fadeInCache != nil)
        #expect(desc.fadeInCache == curveIn)

        #expect(desc.fadeInCache != nil)
        #expect(desc.fadeOutCache == curveOut)

        desc.fade.inTime = 0
        desc.fade.outTime = 0
        #expect(desc.fadeInCache == nil)
        #expect(desc.fadeOutCache == nil)
    }
}
