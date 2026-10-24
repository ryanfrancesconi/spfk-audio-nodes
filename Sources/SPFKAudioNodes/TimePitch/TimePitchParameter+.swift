// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import SPFKAudioBase
import SPFKAudioNodesC

/// Extends the `TimePitchParameter` enum defined in `SPFKAudioNodesC`
extension TimePitchParameter {
    var parameterDef: NodeParameterDef {
        let maxCents = AUValue(TimePitchDescription.semitoneRange.upperBound * 100) + AUValue(TimePitchDescription.centRange.upperBound)

        return switch self {
        case .rate:
            def("rate", "Rate", defaultValue: 1, range: Self.range(TimePitchDescription.rateRange), unit: .rate)
        case .pitchCents:
            def("pitchCents", "Pitch", defaultValue: 0, range: -maxCents ... maxCents, unit: .cents)
        case .tonalityLimit:
            def("tonalityLimit", "Tonality Limit", defaultValue: 0,
                range: 0 ... AUValue(TimePitchDescription.tonalityLimitRange.upperBound), unit: .hertz)
        case .formantShift:
            def("formantShift", "Formant Shift", defaultValue: 0,
                range: Self.range(TimePitchDescription.formantShiftRange), unit: .relativeSemiTones)
        case .formantCorrection:
            def("formantCorrection", "Formant Correction", defaultValue: 0, range: AUValue.unitIntervalRange, unit: .boolean)
        case .formantBase:
            def("formantBase", "Formant Base", defaultValue: 0,
                range: 0 ... AUValue(TimePitchDescription.formantBaseRange.upperBound), unit: .hertz)
        }
    }

    private static func range(_ range: ClosedRange<Double>) -> ClosedRange<AUValue> {
        AUValue(range.lowerBound) ... AUValue(range.upperBound)
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
