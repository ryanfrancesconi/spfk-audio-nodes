// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import Foundation

/// Something a ``StreamPlayer`` can only report after the fact.
///
/// An enum with one case rather than a `failureHandler` closure, so the next condition worth
/// reporting — a stall, an underrun — is a case here rather than a second closure on the player.
public enum StreamPlayerEvent: Sendable {
    /// Decoding stopped partway through a run. Playback is over; the node keeps whatever was
    /// already queued and then falls silent.
    case failed(any Error)
}
