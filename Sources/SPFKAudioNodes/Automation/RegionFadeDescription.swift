// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import SPFKAudioBase
import SPFKAudioNodesC

/// An object representing a fade in and out automation curves on a region of audio in a timeline
public struct RegionFadeDescription {
    /// a constant, 0
    public static let minimumGain: AUValue = 0

    /// the value that the fade should fade to
    public var maximumGain: AUValue = 1

    public var stepResolution: Float = 0.2 {
        willSet {
            if newValue != stepResolution {
                fadeInCache = nil
                fadeOutCache = nil
            }
        }
    }

    /// How long the fade in is
    public var inTime: TimeInterval = 0 {
        willSet {
            if newValue != inTime { fadeInCache = nil }
        }
    }

    /// How long the fade out is
    public var outTime: TimeInterval = 0 {
        willSet {
            if newValue != outTime { fadeOutCache = nil }
        }
    }

    public var segmentDuration: TimeInterval = 0 {
        willSet {
            if newValue != segmentDuration { fadeOutCache = nil }
        }
    }

    public var taper = AudioTaper.default {
        willSet {
            if newValue != taper {
                fadeInCache = nil
                fadeOutCache = nil
            }
        }
    }

    public var sampleRateRatio: Float = 1 {
        willSet {
            if newValue != sampleRateRatio { fadeOutCache = nil }
        }
    }

    /// Time within the file where playback starts. Used by `fadeInCurve()` to compute
    /// the correct initial gain and remaining ramp when starting mid-fade-in.
    /// Must be set alongside `segmentDuration` before calling the curve builders.
    public var playbackStartOffset: TimeInterval = 0 {
        willSet {
            if newValue != playbackStartOffset { fadeInCache = nil }
        }
    }

    public var isFaded: Bool {
        inTime > 0 || outTime > 0
    }

    /// Returns the fader gain at a given playback position within the file.
    ///
    /// Requires `segmentDuration` to be set to `fileDuration - playbackOffset`
    /// so the fade-out zone boundary can be derived.
    public func gainAt(playbackOffset: TimeInterval) -> AUValue {
        if inTime > 0, playbackOffset < inTime {
            let t = Float(playbackOffset / inTime)
            return AUValue(pow(t, taper.value)) * maximumGain
        }
        if outTime > 0 {
            let fileDuration = segmentDuration + playbackOffset
            let fadeOutStart = fileDuration - outTime
            if playbackOffset >= fadeOutStart {
                let s = Float((playbackOffset - fadeOutStart) / outTime)
                return AUValue(max(0, 1.0 - pow(s, taper.inverseValue))) * maximumGain
            }
        }
        return maximumGain
    }

    // MARK: Event cache

    var fadeInCache: AutomationCurve?
    var fadeOutCache: AutomationCurve?

    public init() {}
}
