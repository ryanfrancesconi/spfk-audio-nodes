// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import SPFKAudioNodesC
import SPFKBase

/// Extends the `FaderParameter` enum defined in `SPFKAudioNodesC`
extension FaderParameter {
    /// Gain can be any non-negative number -- however 0 - 4 is
    /// a practical range: 0 ... +12dB
    public static let defaultGainRange: ClosedRange<AUValue> = 0 ... 4

    var parameterDef: NodeParameterDef {
        switch self {
        case .leftGain:
            def("leftGain", "Left Gain", defaultValue: 1, range: Self.defaultGainRange, unit: .linearGain)
        case .rightGain:
            def("rightGain", "Right Gain", defaultValue: 1, range: Self.defaultGainRange, unit: .linearGain)
        case .flipStereo:
            def("flipStereo", "Flip Stereo", defaultValue: 0, range: AUValue.unitIntervalRange, unit: .boolean)
        case .mixToMono:
            def("mixToMono", "Mix To Mono", defaultValue: 0, range: AUValue.unitIntervalRange, unit: .boolean)
        case .monoSource:
            def("monoSource", "Mono Source", defaultValue: 0, range: 0 ... 2, unit: .indexed)
        case .midSideDecode:
            def("midSideDecode", "M/S Decode", defaultValue: 0, range: AUValue.unitIntervalRange, unit: .boolean)
        case .midSideWidth:
            def("midSideWidth", "M/S Width", defaultValue: 1, range: 0 ... 2, unit: .generic)
        case .midSideEncode:
            def("midSideEncode", "M/S Encode", defaultValue: 0, range: AUValue.unitIntervalRange, unit: .boolean)
        }
    }

    private func def(
        _ identifier: String,
        _ name: String,
        defaultValue: AUValue,
        range: ClosedRange<AUValue>,
        unit: AudioUnitParameterUnit
    ) -> NodeParameterDef {
        NodeParameterDef(
            identifier: identifier,
            name: name,
            address: rawValue,
            defaultValue: defaultValue,
            range: range,
            unit: unit
        )
    }
}
