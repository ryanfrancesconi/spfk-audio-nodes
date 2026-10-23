// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import SPFKAudioNodesC
import SPFKBase

// swiftformat:disable consecutiveSpaces

/// Extends the `FaderParameter` enum defined in `SPFKAudioC`
extension FaderParameter {
    /// Gain can be any non-negative number -- however 0 - 4 is
    /// a practical range: 0 ... +12dB
    public static let defaultGainRange: ClosedRange<AUValue> = 0 ... 4

    var parameterAddress: AUParameterAddress { rawValue }

    var identifier: String {
        switch self {
        case .leftGain:     "leftGain"
        case .rightGain:    "rightGain"
        case .flipStereo:   "flipStereo"
        case .mixToMono:    "mixToMono"
        case .monoSource:   "monoSource"
        case .midSideDecode: "midSideDecode"
        case .midSideWidth: "midSideWidth"
        case .midSideEncode: "midSideEncode"
        @unknown default:   ""
        }
    }

    var addressName: String {
        switch self {
        case .leftGain:     "FaderParameterLeftGain"
        case .rightGain:    "FaderParameterRightGain"
        case .flipStereo:   "FaderParameterFlipStereo"
        case .mixToMono:    "FaderParameterMixToMono"
        case .monoSource:   "FaderParameterMonoSource"
        case .midSideDecode: "FaderParameterMidSideDecode"
        case .midSideWidth: "FaderParameterMidSideWidth"
        case .midSideEncode: "FaderParameterMidSideEncode"
        @unknown default:   ""
        }
    }

    var name: String {
        switch self {
        case .leftGain:     "Left Gain"
        case .rightGain:    "Right Gain"
        case .flipStereo:   "Flip Stereo"
        case .mixToMono:    "Mix To Mono"
        case .monoSource:   "Mono Source"
        case .midSideDecode: "M/S Decode"
        case .midSideWidth: "M/S Width"
        case .midSideEncode: "M/S Encode"
        @unknown default:   ""
        }
    }

    var range: ClosedRange<AUValue> {
        switch self {
        case .leftGain,
             .rightGain:    Self.defaultGainRange
        case .flipStereo,
             .mixToMono,
             .midSideDecode,
             .midSideEncode: AUValue.unitIntervalRange
        case .monoSource:   0 ... 2
        case .midSideWidth: 0 ... 2
        @unknown default:   AUValue.unitIntervalRange
        }
    }

    var unit: AudioUnitParameterUnit {
        switch self {
        case .leftGain,
             .rightGain:    .linearGain

        case .flipStereo,
             .mixToMono,
             .midSideDecode,
             .midSideEncode: .boolean

        case .monoSource:   .indexed

        case .midSideWidth: .generic

        @unknown default:   .linearGain
        }
    }

    var defaultValue: AUValue {
        switch self {
        case .leftGain,
             .rightGain:    1
        case .flipStereo,
             .mixToMono,
             .monoSource,
             .midSideDecode,
             .midSideEncode: 0
        case .midSideWidth: 1
        @unknown default:   0
        }
    }

    var parameterDef: NodeParameterDef {
        NodeParameterDef(
            identifier: identifier,
            name: name,
            address: getParameterAddressDSP(addressName),
            defaultValue: defaultValue,
            range: range,
            unit: .boolean
        )
    }
}

// swiftformat:enable consecutiveSpaces
