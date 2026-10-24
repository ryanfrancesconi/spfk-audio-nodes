// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKBase

extension FilePlayer {
    /// Starts the scheduled run.
    ///
    /// **Does not stop the node when one is already playing.** `playerNode.stop()` clears the whole
    /// queue, which by this point holds the segment just scheduled, so stopping here would discard
    /// the run it was called to start and report it complete without a frame having played. A new
    /// run supersedes the previous one in ``schedule(from:to:audioTime:onComplete:)`` instead,
    /// before its own segment is queued.
    public func play() throws {
        try play(at: nil)
    }

    public func play(at startTime: AVAudioTime?) throws {
        guard playerNode.engine?.isRunning == true else {
            throw NSError(description: "FilePlayer.play() Engine isn't running or available - play() canceled for \(audioFile?.url.lastPathComponent ?? "nil")")
        }

        // nil means play immediately, at the time the segment was scheduled for
        playerNode.play(at: startTime)

        if let startTime { lastScheduledTime = startTime }
        isPlaybackArmed = true
    }

    /// Stop playback and cancel any pending scheduled playback or completion events
    public func stop() {
        guard isPlaybackArmed else { return }

        // Both cleared BEFORE playerNode.stop(), which fires the pending dataPlayedBack callbacks:
        // the latch tells the handler an explicit stop() from a natural completion, and the run
        // keeps a callback that arrives after the next one is armed from passing that latch.
        isPlaybackArmed = false
        beginRun()

        playerNode.stop()

        lastScheduledTime = nil
    }
}
