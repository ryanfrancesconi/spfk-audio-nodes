// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import Foundation

/// Identifies which type of click to play at a given metronome position.
public enum MetronomeClick: CaseIterable, Sendable {
    /// The downbeat (first beat) of each measure.
    case bar
    /// A regular beat within the measure (not the downbeat).
    case beat
    /// A sub-beat division (eighth notes, sixteenth notes, etc.).
    case subdivision
}
