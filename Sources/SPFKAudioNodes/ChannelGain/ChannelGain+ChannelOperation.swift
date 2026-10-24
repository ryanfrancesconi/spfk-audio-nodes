// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAudioBase
import SPFKAudioNodesC

extension ChannelGain {
    /// The channel parameters as one operation. A mono operation plays the same signal on both
    /// sides.
    public var channelOperation: ChannelOperation {
        get {
            if mixToMono {
                switch Int(monoSource.rounded()) {
                case 1: return .mono(.left)
                case 2: return .mono(.right)
                default: return .mono(.average)
                }
            }
            if midSideDecode { return .midSideDecode(width: midSideWidth) }
            if midSideEncode { return .midSideEncode }
            if flipStereo { return .swap }
            return .none
        }
        set {
            var state = ChannelGainOperationState(
                flipStereo: false,
                mixToMono: false,
                monoSource: UInt8(monoSource.rounded()),
                midSideDecode: false,
                midSideEncode: false,
                midSideWidth: midSideWidth
            )

            switch newValue {
            case .none:
                break
            case .swap:
                state.flipStereo = true
            case let .mono(source):
                state.mixToMono = true
                state.monoSource = switch source {
                case .average: 0
                case .left: 1
                case .right: 2
                }
            case let .midSideDecode(width):
                state.midSideDecode = true
                let range = ChannelOperation.widthRange
                state.midSideWidth = min(max(width, range.lowerBound), range.upperBound)
            case .midSideEncode:
                state.midSideEncode = true
            }

            // One store, so a render never plays half an operation. The parameter writes after it
            // keep the AU's parameter tree current; each lands a value the DSP already holds.
            if let dsp = (avAudioNode.auAudioUnit as? SPFKAudioUnit)?.dsp {
                setOperationStateChannelGainDSP(dsp, state)
            }

            mixToMono = state.mixToMono
            monoSource = AUValue(state.monoSource)
            midSideDecode = state.midSideDecode
            midSideWidth = state.midSideWidth
            midSideEncode = state.midSideEncode
            flipStereo = state.flipStereo
        }
    }
}
