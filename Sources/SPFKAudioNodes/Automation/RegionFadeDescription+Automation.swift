// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase

// NOTE: `AutomationEvent` is a SPFKAudioC C++ struct pulled from AudioKit

extension RegionFadeDescription {
    /// Generate an `AutomationEvent` curve from internal values
    ///
    /// - Returns: `AutomationCurve`
    public mutating func fadeInCurve() -> AutomationCurve? {
        guard fade.inTime > 0 else {
            fadeInCache = nil
            return nil
        }

        // Playback starts at or past the end of the fade-in — no automation needed.
        guard playbackStartOffset < fade.inTime else {
            fadeInCache = nil
            return nil
        }

        if let fadeInCache {
            return fadeInCache
        }

        let rampDuration = fade.inTime.float

        let points = [
            ParameterAutomationPoint(
                targetValue: Self.minimumGain,
                startTime: -0.1,
                rampDuration: 0,
                rampTaper: AudioTaper.linear.value,
                rampSkew: AudioTaper.linear.skew
            ),

            ParameterAutomationPoint(
                targetValue: maximumGain,
                startTime: 0,
                rampDuration: rampDuration,
                rampTaper: fade.taper.value,
                rampSkew: fade.taper.skew
            ),
        ]

        var curve = AutomationCurve(points: points, resolution: stepResolution(for: fade.inTime))

        // Starting mid-fade-in: crop to the current offset so the automation
        // begins at the correct gain value, mirroring the fadeOutCurve() pattern.
        if playbackStartOffset > 0 {
            do {
                try curve.crop(after: Float(playbackStartOffset))
            } catch {
                Log.error(error)
            }
        }

        fadeInCache = curve

        return curve
    }

    /// Generate a fade out curve for a region of audio
    ///
    /// - Parameters:
    ///   - segmentDuration: Total duration of the file segment. This is used to calculate
    ///   how far in advance the fade out should begin.
    ///
    ///   - sampleRateRatio: sample rate time ratio if needed when rendering
    ///
    /// - Returns: `AutomationCurve`
    public mutating func fadeOutCurve() -> AutomationCurve? {
        guard fade.outTime > 0 else {
            fadeOutCache = nil
            return nil
        }

        if let fadeOutCache {
            return fadeOutCache
        }

        let rampDuration = fade.outTime.float / sampleRateRatio

        // offset: when the start of the fade out should occur. If it is negative, playback is starting inside the curve.
        // in that case segmentDuration is < outTime
        let offset = Float(segmentDuration - fade.outTime) / sampleRateRatio
        let isInsideCurve = offset < 0
        let startTime = max(0, offset.float)

        let points = [
            ParameterAutomationPoint(
                targetValue: maximumGain,
                startTime: startTime - 0.02,
                rampDuration: 0.02,
                rampTaper: AudioTaper.linear.value,
                rampSkew: AudioTaper.linear.skew
            ),

            // Use inverseValue so the ramp produces gain ≈ 1 - t^(1/taper):
            // a fast initial drop that levels off toward silence. This mirrors
            // the perceptual character of the fade-in (t^taper: slow rise, fast
            // finish) and matches the visual convention — the ideal formula
            // (1-t)^taper isn't expressible in a single AURampParameter point.
            ParameterAutomationPoint(
                targetValue: Self.minimumGain,
                startTime: startTime,
                rampDuration: rampDuration,
                rampTaper: fade.taper.inverseValue,
                rampSkew: fade.taper.skew
            ),
        ]

        var curve = AutomationCurve(points: points, resolution: stepResolution(for: fade.outTime))

        if isInsideCurve {
            do {
                try curve.crop(after: abs(offset))
            } catch {
                Log.error(error)
            }
        }

        fadeOutCache = curve

        return curve
    }
}

extension RegionFadeDescription {
    func stepResolution(for duration: TimeInterval) -> Float {
        var resolution = stepResolution

        let time = Float(duration)

        // make sure the resolution is low enough to have multiple points
        if time < resolution * 3 {
            resolution = time / 3
        }

        return resolution
    }
}
