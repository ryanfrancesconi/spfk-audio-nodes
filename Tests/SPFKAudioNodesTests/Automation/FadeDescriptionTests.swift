// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import Foundation
import SPFKBase
import Testing

@testable import SPFKAudioNodes
@testable import SPFKAudioNodesC

@Suite(.tags(.automation))
struct FadeDescriptionTests {
    // MARK: - in

    @Test func fadeInReturnsNilWhenZeroTime() {
        var desc = RegionFadeDescription()
        desc.inTime = 0
        #expect(desc.fadeInCurve() == nil)
    }

    @Test func fadeInTruncatingLastPointDuration() throws {
        var desc = RegionFadeDescription()
        desc.maximumGain = 1
        desc.stepResolution = 0.2

        // should be a value that doesn't divide by stepResolution
        desc.inTime = 4.305577
        desc.taper = .default
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
        desc.inTime = 1
        desc.taper = .linear

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
        desc.inTime = 1
        desc.taper = .default

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
        desc.inTime = 1
        desc.taper = .reverseAudio

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
        desc.outTime = 0
        desc.segmentDuration = 1
        #expect(desc.fadeOutCurve() == nil)
    }

    @Test func fadeOutTaperOneSecond() throws {
        var desc = RegionFadeDescription()
        desc.outTime = 1
        desc.segmentDuration = 1
        desc.stepResolution = 0.2
        desc.taper = .default

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
        desc.outTime = 1
        desc.segmentDuration = 0.8   // starts 0.2s into a 1s fade
        desc.taper = .default

        let curve = desc.fadeOutCurve()
        let events = try #require(curve?.events)

        #expect(events == desc.fadeOutCache?.events)

        // Cropped curve must have fewer events than the full 1s fade.
        var fullDesc = RegionFadeDescription()
        fullDesc.outTime = 1
        fullDesc.segmentDuration = 1
        fullDesc.taper = .default
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

    // MARK: - cache

    @Test func fadeCache() throws {
        var desc = RegionFadeDescription()
        desc.inTime = 1
        desc.outTime = 1
        desc.segmentDuration = 2
        desc.taper = .default

        let curveIn = desc.fadeInCurve()
        let curveOut = desc.fadeOutCurve()

        #expect(desc.fadeInCache != nil)
        #expect(desc.fadeInCache == curveIn)

        #expect(desc.fadeInCache != nil)
        #expect(desc.fadeOutCache == curveOut)

        desc.inTime = 0
        desc.outTime = 0
        #expect(desc.fadeInCache == nil)
        #expect(desc.fadeOutCache == nil)
    }
}
