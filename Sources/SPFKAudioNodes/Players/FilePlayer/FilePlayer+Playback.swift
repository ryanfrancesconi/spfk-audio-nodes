// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import Foundation
import SPFKBase

extension FilePlayer {
    public func play() throws {
        guard playerNode.engine?.isRunning == true else {
            throw NSError(description: "FilePlayer.play() Engine isn't running or available - play() canceled for \(audioFile?.url.lastPathComponent ?? "nil")")
        }

        if isPlaying {
            playerNode.stop()
        }

        // nil means play immediately; the segment's start time was set in scheduleSegment
        playerNode.play(at: nil)

        isPlaying = true
    }

    /// Stop playback and cancel any pending scheduled playback or completion events
    public func stop() {
        guard isPlaying else { return }

        // Set isPlaying false BEFORE playerNode.stop() so the completionHandler
        // can distinguish an explicit stop() (isPlaying == false) from a natural
        // completion (isPlaying == true). playerNode.stop() fires pending
        // dataPlayedBack callbacks synchronously on some code paths.
        isPlaying = false
        playerNode.stop()

        lastScheduledTime = nil
    }
}
