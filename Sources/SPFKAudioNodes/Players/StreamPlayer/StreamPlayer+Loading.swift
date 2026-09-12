// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import os
import SPFKAudioBase
import SPFKAUHost
import SPFKBase

extension StreamPlayer {
    // MARK: - Loading

    /// Takes ownership of `source`.
    ///
    /// - Parameters:
    ///   - source: the stream to play. Handed over rather than shared — it holds a file position,
    ///     so the feed queue must be the only thing driving it from here on.
    ///   - url: what the source is reading, for a caller that identifies a loaded player by file.
    ///   - duration: the source's length. Taken as a parameter because a container states it in its
    ///     header, where the decoded stream only reveals it by being read to the end.
    public func load(source: some SeekablePCMSource, url: URL, duration: TimeInterval) async throws {
        // Unconditionally, not `if isPlaying`: a run armed by `schedule` and never played still has
        // a feed task decoding against the outgoing source, and `stop()` cancels before its own
        // `isPlaying` guard for exactly that reason. Taking the shape FilePlayer uses here left the
        // old task reading a source this method is in the middle of replacing.
        stop()

        // Cancelling does not end the read the task is inside, and everything below is state that
        // read is still using — `processingFormat` and `source` most of all. Bounded by one chunk.
        await feedTask?.value
        feedTask = nil

        guard duration > 0 else {
            throw NSError(file: #file, function: #function, description: "\(url.lastPathComponent) reports no duration")
        }

        // A player node renders one format for its lifetime, so a source of a different format
        // needs a different player — the same rule `FilePlayer` states.
        if let processingFormat, processingFormat != source.processingFormat {
            let message = "Processing format doesn't match. This source is a different format than the previously loaded one. " +
                "You should make a new StreamPlayer instance and reconnect."
            throw NSError(file: #file, function: #function, description: message)
        }

        self.url = url
        self.duration = duration
        processingFormat = source.processingFormat
        playbackRange = 0 ... duration

        // Direct, because `stop()` above cancelled any feed task and nothing else reads this until
        // `schedule` hands it to a new one.
        self.source = source
    }

    /// Releases the source, once nothing is reading it.
    ///
    /// **`async` because the wait is the point.** `stop()` cancels the feed task and returns, and a
    /// read already inside the decoder stays there until it returns — so a synchronous teardown
    /// hands the source back, reassigns ``processingFormat``/``framesRemaining``/``runAnchor`` and
    /// detaches the node while that read is still running. Awaiting the task is what makes
    /// "unloaded" mean nothing is in flight. Bounded by one chunk decode.
    public func unload() async {
        if isPlaybackArmed {
            stop()
        }

        // Cancel then await, in that order and both: cancellation makes the loop exit at its next
        // check, and the await is what waits for the read it is currently inside. Awaiting a
        // finished task is free.
        feedTask?.cancel()
        await feedTask?.value
        feedTask = nil

        endRun()

        url = nil
        duration = nil
        processingFormat = nil
        playbackRange = nil

        source = nil
        runAnchor = nil
        framesRemaining = 0
    }

    public func updateTimeRange(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil
    ) throws {
        guard let duration else {
            throw NSError(file: #file, function: #function, description: "No source is loaded")
        }

        let lowerBound = max(0, startingTime ?? 0)
        let upperBound = min(duration, endingTime ?? duration)

        guard lowerBound < upperBound else {
            throw NSError(file: #file, function: #function, description: "invalid edit range \(lowerBound)...\(upperBound)")
        }

        playbackRange = lowerBound ... upperBound
    }
}
