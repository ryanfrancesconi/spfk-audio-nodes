// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKAUHost
import SPFKBase

extension ChannelGain: AudioEngineNode {
    public var inputNode: AVAudioNode? { avAudioNode }
    public var outputNode: AVAudioNode? { avAudioNode }

    public var isBypassed: Bool {
        get { avAudioNode.auAudioUnit.shouldBypassEffect }
        set { avAudioNode.auAudioUnit.shouldBypassEffect = newValue }
    }
}

/// Stereo gain and channel operation: independent left/right gain, swap, mono and mid/side,
/// with gain automation.
public class ChannelGain: AudioEngineNodeAU, TypeDescribable {
    public static let version: UInt32 = 1

    public private(set) var audioComponentDescription: AudioComponentDescription

    /// Underlying AVAudioNode
    public private(set) var avAudioNode: AVAudioNode

    // MARK: - Parameters

    /// Left Channel Amplification Factor
    @Parameter(ChannelGainParameter.leftGain.parameterDef) public var leftGain: AUValue

    /// Right Channel Amplification Factor
    @Parameter(ChannelGainParameter.rightGain.parameterDef) public var rightGain: AUValue

    /// Flip left and right signal
    @Parameter(ChannelGainParameter.flipStereo.parameterDef) public var flipStereo: Bool

    /// Specification for whether to mix the stereo signal down to mono
    /// Make the output on left and right both be the same combination of incoming left and mixed equally
    @Parameter(ChannelGainParameter.mixToMono.parameterDef) public var mixToMono: Bool

    /// Which signal `mixToMono` keeps: 0 average, 1 left, 2 right
    @Parameter(ChannelGainParameter.monoSource.parameterDef) public var monoSource: AUValue

    /// Decode a mid/side input to left/right at `midSideWidth`
    @Parameter(ChannelGainParameter.midSideDecode.parameterDef) public var midSideDecode: Bool

    /// Side gain of the mid/side decode, 0 ... 2
    @Parameter(ChannelGainParameter.midSideWidth.parameterDef) public var midSideWidth: AUValue

    /// Encode a left/right input to mid/side
    @Parameter(ChannelGainParameter.midSideEncode.parameterDef) public var midSideEncode: Bool

    /// The manual gain of both channels, from 0 ... x: what automation multiplies or replaces,
    /// not necessarily what renders. ``NodeAutomation/renderedValue(of:)`` reads that.
    open var gain: AUValue {
        get { leftGain }
        set {
            leftGain = newValue
            rightGain = newValue
        }
    }

    /// Automation of `leftGain` and `rightGain`.
    public let automation: NodeAutomation

    /// Amplification Factor in db
    public var dB: AUValue {
        get { gain.dBValue }
        set { gain = newValue.linearValue }
    }

    // MARK: - Initialization

    /// Initialize this channel gain node
    ///
    /// - Parameters:
    ///   - gain: Amplification factor (Default: 1, Minimum: 0)
    ///   - gainRange: AU parameter range for left/right gain. Defaults to `ChannelGainParameter.defaultGainRange`.
    ///     Pass a wider range (e.g. `0...16`) when this channel gain will be driven by normalization automation
    ///     that may exceed the default +12 dB ceiling.
    ///
    public init(gain: AUValue = 1, gainRange: ClosedRange<AUValue> = ChannelGainParameter.defaultGainRange) async throws {
        audioComponentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kSPFKSubTypeChannelGain,
            componentManufacturer: kAudioUnitManufacturer_Spongefork,
            componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
            componentFlagsMask: 0
        )

        avAudioNode = try await AVAudioUnit.instantiateLocal(
            with: audioComponentDescription,
            named: Self.typeName,
            version: Self.version
        )

        automation = try NodeAutomation(avAudioNode)

        if gainRange != ChannelGainParameter.defaultGainRange {
            $leftGain.def.range = gainRange
            $rightGain.def.range = gainRange
        }

        setupParameters()

        leftGain = gain
        rightGain = gain
        channelOperation = .none
    }

    deinit {
        // `detachNodes()` is async and a deinit cannot await. This is its whole body for a ChannelGain,
        // which has no background reader to wait for.
        try? detachIONodes()
    }
}
