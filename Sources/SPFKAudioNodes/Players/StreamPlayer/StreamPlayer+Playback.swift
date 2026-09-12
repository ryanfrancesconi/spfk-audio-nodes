// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import os
import SPFKAudioBase
import SPFKAUHost
import SPFKBase

// MARK: - Playback

extension StreamPlayer {
    public func play() throws {
        guard playerNode.engine?.isRunning == true else {
            throw NSError(description: "StreamPlayer.play() Engine isn't running or available - play() canceled for \(url?.lastPathComponent ?? "nil")")
        }

        if isPlaybackArmed {
            playerNode.stop()
        }

        // nil means play immediately; the run's start time was given to the first buffer.
        playerNode.play(at: nil)

        isPlaybackArmed = true
    }

    /// Stops playback and cancels the run.
    ///
    /// **Returns without waiting for the feed task**, so a decode already inside the source may
    /// still be running when it does — deliberately, because this is on the playback path and must
    /// not block. Everything that goes on to touch the source waits instead:
    /// ``schedule(from:to:audioTime:onComplete:)`` before it seeks, ``unload()`` and ``load(source:url:duration:)``
    /// before they release or replace it.
    public func stop() {
        // **Cancelled before the `isPlaying` guard, not after.** A run is armed by `schedule` and
        // starts feeding immediately, so a player that was scheduled but never played still has a
        // task decoding and calling `scheduleBuffer`. Returning early there left it running while
        // the host tore the graph down to load the next file — which crashes inside the engine, and
        // looks like a fault in whatever was loaded next rather than in what was left behind.
        //
        // **The handle is kept, not cleared.** Cancelling does not end a read already inside the
        // source, and the next `schedule` is what waits for it — dropping the handle here leaves it
        // nothing to wait on, which is the restart race with the fix apparently applied.
        feedTask?.cancel()

        guard isPlaybackArmed else {
            // Still clear the run, or a stale generation's callbacks outlive it.
            endRun()

            lastScheduledTime = nil
            return
        }

        // Bumped before `playerNode.stop()`, which fires pending completion handlers: without this
        // one of them would be taken for the current run's. Cancelling the task is not enough on its
        // own, since cancellation is observed rather than immediate.
        endRun()

        isPlaybackArmed = false
        playerNode.stop()

        lastScheduledTime = nil
    }

    /// Fences the current run's callbacks and releases the feed task if it is waiting.
    ///
    /// `AsyncStream.next()` does return nil on cancellation — measured, not assumed — so the task
    /// wakes from `feedTask?.cancel()` alone. Finishing here covers the path that has no
    /// cancellation to rely on: `schedule` supersedes a run while its task may still be observing
    /// the old generation, and a continuation left live would keep the loop parked on a stream
    /// nothing will ever yield to again.
    func endRun() {
        feedState.withLock { _ = $0.endRun(replacingSignalWith: nil) }

        // The run is over, so nothing may repeat it. Left set, `enqueueRepeat` would pass its
        // `currentRun` guard and then quietly do nothing on the generation check.
        currentRun = nil
        currentSignals = nil
    }
}
