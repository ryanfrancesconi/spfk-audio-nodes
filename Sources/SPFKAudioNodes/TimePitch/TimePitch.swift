// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKAUHost
import SPFKBase

extension TimePitch: AudioEngineNode {
    public var inputNode: AVAudioNode? { avAudioNode }
    public var outputNode: AVAudioNode? { avAudioNode }

    /// A bypassed node passes its input through and reports no latency. Changing it resets the
    /// stretcher at the next block.
    public var isBypassed: Bool {
        get { avAudioNode.auAudioUnit.shouldBypassEffect }
        set { avAudioNode.auAudioUnit.shouldBypassEffect = newValue }
    }
}

/// Rate and pitch through Signalsmith Stretch, as an insert: it pulls `rate` source frames for
/// each frame it renders.
public class TimePitch: AudioEngineNodeAU, TypeDescribable {
    public static let version: UInt32 = 1

    public private(set) var audioComponentDescription: AudioComponentDescription

    /// Underlying AVAudioNode
    public private(set) var avAudioNode: AVAudioNode

    // MARK: - Parameters

    /// Output speed relative to the source; above 1 is faster.
    @Parameter(TimePitchParameter.rate.parameterDef) public var rate: AUValue

    @Parameter(TimePitchParameter.pitchCents.parameterDef) public var pitchCents: AUValue

    /// In Hz; 0 is off.
    @Parameter(TimePitchParameter.tonalityLimit.parameterDef) public var tonalityLimit: AUValue

    /// In semitones.
    @Parameter(TimePitchParameter.formantShift.parameterDef) public var formantShift: AUValue

    @Parameter(TimePitchParameter.formantCorrection.parameterDef) public var formantCorrection: Bool

    /// In Hz; 0 is automatic detection.
    @Parameter(TimePitchParameter.formantBase.parameterDef) public var formantBase: AUValue

    public private(set) var quality: TimePitchQuality = .best

    private var dsp: DSPRef? {
        (avAudioNode.auAudioUnit as? SPFKAudioUnit)?.dsp
    }

    // MARK: - Initialization

    public init() async throws {
        audioComponentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kSPFKSubTypeTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Spongefork,
            componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
            componentFlagsMask: 0
        )

        avAudioNode = try await AVAudioUnit.instantiateLocal(
            with: audioComponentDescription,
            named: Self.typeName,
            version: Self.version
        )

        setupParameters()

        rate = 1
        pitchCents = 0
    }

    deinit {
        // `detachNodes()` is async and a deinit cannot await. This is its whole body for a TimePitch,
        // which has no background reader to wait for.
        try? detachIONodes()
    }

    // MARK: - Settings

    public func apply(_ description: TimePitchDescription) {
        rate = AUValue(description.rate)
        pitchCents = AUValue(description.pitchCents)
        tonalityLimit = AUValue(description.tonalityLimitHz)
        formantShift = AUValue(description.formantSemitones)
        formantCorrection = description.formantCorrection
        formantBase = AUValue(description.formantBaseHz)
    }

    /// Builds a stretcher at `quality` here and swaps it in at the next render block, which resets
    /// the audio once, like a seek. Before render resources exist it only sets what they will use.
    public func setQuality(_ quality: TimePitchQuality) {
        self.quality = quality
        guard let dsp else { return }
        setQualityTimePitchDSP(dsp, quality == .efficient ? .efficient : .best)
    }

    /// The time from a source frame entering to its being heard, at a constant `rate`. 0 before
    /// render resources exist.
    public func latency(atRate rate: Double) -> TimeInterval {
        guard let dsp else { return 0 }
        return latencyAtRateTimePitchDSP(dsp, rate)
    }

    /// Renders silence and pulls nothing until `sampleTime`, an output sample time, then pulls
    /// the upstream. Returns where the upstream player must be started: its first pull carries
    /// that sample time.
    public func holdUntil(sampleTime: AVAudioFramePosition) -> AVAudioFramePosition? {
        guard let dsp else { return nil }
        return AVAudioFramePosition(holdUntilSampleTimeTimePitchDSP(dsp, Double(sampleTime)))
    }

    /// As ``holdUntil(sampleTime:)``, at a host time.
    public func holdUntil(hostTime: UInt64) -> AVAudioFramePosition? {
        guard let dsp else { return nil }
        return AVAudioFramePosition(holdUntilHostTimeTimePitchDSP(dsp, hostTime))
    }

    /// Every input frame pulled since render resources were allocated.
    var inputFramesPulled: Int64 {
        guard let dsp else { return 0 }
        return inputFramesPulledTimePitchDSP(dsp)
    }
}
