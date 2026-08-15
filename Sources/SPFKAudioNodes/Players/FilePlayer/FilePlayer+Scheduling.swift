// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAudioBase
import SPFKBase

extension FilePlayer {
    public func schedule(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil,
        when scheduledTime: TimeInterval = 0,
        hostTime: UInt64? = nil,
        onComplete: (@Sendable () -> Void)? = nil
    ) throws {
        let hostTime = hostTime ?? mach_absolute_time()

        guard let audioTime: AVAudioTime = audioTime(scheduledTime: scheduledTime, hostTime: hostTime) else {
            throw NSError(file: #file, function: #function, description: "Failed to create scheduled time")
        }

        try schedule(from: startingTime, to: endingTime, audioTime: audioTime, onComplete: onComplete)
    }

    public func schedule(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil,
        audioTime: AVAudioTime,
        onComplete: (@Sendable () -> Void)? = nil
    ) throws {
        // Only update the time range if the requested bounds differ from current
        let requestedStart = startingTime ?? 0
        let requestedEnd = endingTime ?? duration ?? 0

        if playbackRange?.lowerBound != requestedStart || playbackRange?.upperBound != requestedEnd {
            try updateTimeRange(from: startingTime, to: endingTime)
        }

        guard let playbackRange else {
            throw NSError(file: #file, function: #function, description: "invalid edit range")
        }

        try scheduleSegment(over: playbackRange, at: audioTime, onComplete: onComplete)
    }

    /// Queues a pass over `startingTime...endingTime`, after whatever is already scheduled.
    ///
    /// `AVAudioPlayerNode` plays a command with no time immediately after the last one, so looping
    /// is repeated segments rather than segments timed against a clock.
    /// **A repeat states its range rather than redefining the player's.** `playbackRange` is what
    /// the run plays and what `currentTime` is measured against; a loop pass is a separate span, and
    /// folding the two together moved the playhead's origin and — called with no arguments — reset
    /// the range to the whole file, so a trimmed player looped everything. ``StreamPlayer`` states
    /// it this way, and the protocol requires the two to answer alike.
    public func enqueueRepeat(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil,
        onComplete: (@Sendable () -> Void)? = nil
    ) throws {
        guard let playbackRange else {
            throw NSError(file: #file, function: #function, description: "Nothing is scheduled to repeat")
        }

        let lowerBound = startingTime ?? playbackRange.lowerBound
        let upperBound = endingTime ?? playbackRange.upperBound

        guard lowerBound < upperBound else {
            throw NSError(file: #file, function: #function, description: "invalid repeat range \(lowerBound)...\(upperBound)")
        }

        try scheduleSegment(over: lowerBound ... upperBound, at: nil, onComplete: onComplete)
    }

    /// a segment must be scheduled before you can play
    private func scheduleSegment(
        over range: ClosedRange<TimeInterval>,
        at audioTime: AVAudioTime?,
        onComplete: (@Sendable () -> Void)? = nil
    ) throws {
        guard let audioFile else {
            throw NSError(file: #file, function: #function, description: "No audio file is loaded")
        }

        // A repeat carries no time — it queues behind what is already scheduled — so it must not
        // clear the run's start time and report the player as unscheduled, and it belongs to the
        // run it repeats rather than starting one.
        if let audioTime {
            // Supersede whatever is playing here rather than in play(), which reaches the node
            // only after this segment is queued and would clear it along with the old one.
            if isPlaybackArmed {
                stop()
            }

            beginRun()

            lastScheduledTime = audioTime
        }

        let run = currentRun

        let sampleRate: Double = audioFile.fileFormat.sampleRate
        let startFrame = AVAudioFramePosition(range.lowerBound * sampleRate)
        let endFrame = AVAudioFramePosition(range.upperBound * sampleRate)
        let totalFrames = endFrame - startFrame

        guard totalFrames > 0 else {
            throw NSError(file: #file, function: #function, description: "Unable to schedule file. totalFrames to play: \(totalFrames). audioFile.length: \(audioFile.length)")
        }

        let frameCount = AVAudioFrameCount(totalFrames)

        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: audioTime,
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [weak self, onComplete] _ in
                guard let self, let onComplete else { return }

                // Two questions, and the callbacks playerNode.stop() fires need both answered. The
                // latch, cleared before that stop(), says whether an explicit stop() ended the run;
                // for a natural completion it is still true. Deliberately not `isPlaying`: a
                // stopped engine would suppress a genuine completion. The run says whether this
                // callback is the live run's — a callback delivered after the next run has armed
                // the latch again passes it on its own.
                guard isPlaybackArmed, currentRun == run else { return }

                onComplete()
            }
        )

        playerNode.prepare(withFrameCount: frameCount)
    }

    // MARK: - Helpers

    private func audioTime(scheduledTime: TimeInterval, hostTime: UInt64) -> AVAudioTime? {
        if renderingMode == .offline {
            guard let sampleRate else { return nil }

            // needs to be a sample based AVAudioTime for offline rendering
            let sampleTime = AVAudioFramePosition(scheduledTime * sampleRate)

            let sampleAVTime = AVAudioTime(
                hostTime: hostTime,
                sampleTime: sampleTime,
                atRate: sampleRate
            )

            return sampleAVTime

        } else {
            return AVAudioTime(hostTime: hostTime).offset(seconds: scheduledTime)
        }
    }
}
