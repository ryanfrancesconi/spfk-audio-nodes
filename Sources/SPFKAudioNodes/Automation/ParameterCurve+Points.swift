// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import Foundation
import SPFKAudioBase

extension ParameterCurve {
    /// Track automation through UI points: a segment from each point to the next, on `taper` going
    /// up and on its inverse going down, holding the first point's gain before it.
    public init(points: [AutomationPoint], taper: AudioTaper = .default) throws {
        let points = points.sorted()

        guard let first = points.first else { throw ValidationError.empty }
        guard points.count > 1 else {
            try self.init([CurveSegment(start: first.time, end: first.time, startValue: first.gain, endValue: first.gain)])
            return
        }

        let segments = zip(points, points.dropFirst()).map { from, to in
            let value = from.gain > to.gain ? 1 / Double(taper.value) : Double(taper.value)

            return CurveSegment(
                start: from.time,
                end: to.time,
                startValue: from.gain,
                endValue: to.gain,
                shape: .taper(value: value, skew: Double(taper.skew))
            )
        }

        try self.init(segments)
    }
}
