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

    /// Fade-in/out durations and tapers. Mutating any sub-field invalidates the relevant curve cache.
    public var fade = FadeDescription() {
        willSet {
            if newValue.inTime != fade.inTime { fadeInCache = nil }
            if newValue.outTime != fade.outTime { fadeOutCache = nil }
            if newValue.inTaper != fade.inTaper { fadeInCache = nil }
            if newValue.outTaper != fade.outTaper { fadeOutCache = nil }
        }
    }

    public var segmentDuration: TimeInterval = 0 {
        willSet {
            if newValue != segmentDuration { fadeOutCache = nil }
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

    public var isFaded: Bool { !fade.isEmpty }

    /// Returns the fader gain at a given playback position within the file.
    ///
    /// Requires `segmentDuration` to be set to `fileDuration - playbackOffset`
    /// so the fade-out zone boundary can be derived.
    public func gainAt(playbackOffset: TimeInterval) -> AUValue {
        if fade.inTime > 0, playbackOffset < fade.inTime {
            let t = Float(playbackOffset / fade.inTime)
            return Float(fade.inTaper.gainAt(t: Double(t))) * maximumGain
        }
        if fade.outTime > 0 {
            let fileDuration = segmentDuration + playbackOffset
            let fadeOutStart = fileDuration - fade.outTime
            if playbackOffset >= fadeOutStart {
                let s = Float((playbackOffset - fadeOutStart) / fade.outTime)
                return Float(fade.outTaper.fadeOutGainAt(s: Double(s))) * maximumGain
            }
        }
        return maximumGain
    }

    // MARK: Event cache

    var fadeInCache: AutomationCurve?
    var fadeOutCache: AutomationCurve?

    public init() {}
}
