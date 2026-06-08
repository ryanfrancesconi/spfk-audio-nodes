// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import AVFoundation
import SPFKAudioBase
import SPFKBase

/// Point-in-time snapshot of host transport and musical context captured on each render cycle.
public struct TransportSnapshot: Sendable {
    // MARK: - Musical Context

    public var currentTempo: Double = 0
    public var timeSignatureNumerator: Double = 0
    public var timeSignatureDenominator: Int = 0
    public var currentBeatPosition: Double = 0
    public var currentMeasureDownbeatPosition: Double = 0
    public var sampleOffsetToNextBeat: Int = 0

    // MARK: - Transport State

    public var transportFlags: AUHostTransportStateFlags = []
    public var currentSamplePosition: Double = 0
    public var cycleStartBeatPosition: Double = 0
    public var cycleEndBeatPosition: Double = 0

    public init() {}
}

/// In-process `AUAudioUnit` that reads `musicalContextBlock` and `transportStateBlock` on every
/// render cycle. Audio passes through unmodified; the block reads are the only work performed.
public final class TransportValidationAU: AUAudioUnit, @unchecked Sendable {
    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: "tval".fourCC ?? 0,
        componentManufacturer: kAudioUnitManufacturer_Spongefork,
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask: 0
    )

    /// Most-recent values read from the host blocks. Written on the render thread; read on the main
    /// thread by the inspector UI. The race is benign — the UI reads stale values at worst.
    nonisolated(unsafe) public var snapshot = TransportSnapshot()

    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    public override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    public override var canProcessInPlace: Bool { true }

    public override var channelCapabilities: [NSNumber] {
        [NSNumber(value: 2), NSNumber(value: 2)]
    }

    override public init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        _inputBusses = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .input,
            busses: [try AUAudioUnitBus(format: format)]
        )
        _outputBusses = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .output,
            busses: [try AUAudioUnitBus(format: format)]
        )
        parameterTree = AUParameterTree.createTree(withChildren: [])
    }

    override public var internalRenderBlock: AUInternalRenderBlock {
        return { [weak self]
            actionFlags, timestamp, frameCount,
            outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in

            guard let self else { return noErr }

            let status = pullInputBlock?(actionFlags, timestamp, frameCount, 0, outputData) ?? noErr
            guard status == noErr else { return status }

            var snap = TransportSnapshot()

            var tempo: Double = 0, num: Double = 0, denom: Int = 0
            var beat: Double = 0, downbeat: Double = 0
            var sampleOffset: Int = 0

            _ = self.musicalContextBlock?(&tempo, &num, &denom, &beat, &sampleOffset, &downbeat)
            snap.currentTempo = tempo
            snap.timeSignatureNumerator = num
            snap.timeSignatureDenominator = denom
            snap.currentBeatPosition = beat
            snap.currentMeasureDownbeatPosition = downbeat
            snap.sampleOffsetToNextBeat = sampleOffset

            var flags = AUHostTransportStateFlags()
            var samplePos: Double = 0
            var cycleStart: Double = 0, cycleEnd: Double = 0

            _ = self.transportStateBlock?(&flags, &samplePos, &cycleStart, &cycleEnd)
            snap.transportFlags = flags
            snap.currentSamplePosition = samplePos
            snap.cycleStartBeatPosition = cycleStart
            snap.cycleEndBeatPosition = cycleEnd

            self.snapshot = snap
            return noErr
        }
    }
}
