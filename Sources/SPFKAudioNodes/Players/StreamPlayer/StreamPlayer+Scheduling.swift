// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import os
import SPFKAudioBase
import SPFKAUHost
import SPFKBase

// MARK: - Scheduling

extension StreamPlayer {
    public func schedule(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil,
        when scheduledTime: TimeInterval = 0,
        hostTime: UInt64? = nil,
        onComplete: (@Sendable () -> Void)? = nil
    ) async throws {
        let hostTime = hostTime ?? mach_absolute_time()

        guard let audioTime = audioTime(scheduledTime: scheduledTime, hostTime: hostTime) else {
            throw NSError(file: #file, function: #function, description: "Failed to create scheduled time")
        }

        try await schedule(from: startingTime, to: endingTime, audioTime: audioTime, onComplete: onComplete)
    }

    /// The same split ``FilePlayer`` makes, and for the same reason: an offline render has no
    /// hardware clock to anchor against, so the start has to be expressed in samples.
    private func audioTime(scheduledTime: TimeInterval, hostTime: UInt64) -> AVAudioTime? {
        guard renderingMode == .offline else {
            return AVAudioTime(hostTime: hostTime).offset(seconds: scheduledTime)
        }

        guard let sampleRate else { return nil }

        return AVAudioTime(
            hostTime: hostTime,
            sampleTime: AVAudioFramePosition(scheduledTime * sampleRate),
            atRate: sampleRate
        )
    }

    /// Whether the engine is rendering offline or in real time.
    public var renderingMode: AVAudioEngineManualRenderingMode? {
        playerNode.engine?.manualRenderingMode
    }

    /// Seeks the source to `startingTime` and fills the node's queue enough to start.
    ///
    /// Returns once ``prefillBuffers`` are queued, so the run is playable the moment it returns; the
    /// rest of the file is decoded by the feed task behind it. A long file therefore costs the
    /// caller one seek and two buffers, not its length.
    ///
    /// **`async` for the prefill, not for thread safety.** `AVAudioPlayerNode` synchronizes its own
    /// scheduling internally and may be driven from any thread; what it asks for (see
    /// `AVAudioPlayerNode.h`) is that calls made *from a completion handler* be serialized against
    /// the rest, which is why every node call here happens on this path or on the single feed task
    /// and never in a callback.
    public func schedule(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil,
        audioTime: AVAudioTime,
        onComplete: (@Sendable () -> Void)? = nil
    ) async throws {
        guard let sampleRate else {
            throw NSError(file: #file, function: #function, description: "No source is loaded")
        }

        let requestedStart = startingTime ?? 0
        let requestedEnd = endingTime ?? duration ?? 0

        if playbackRange?.lowerBound != requestedStart || playbackRange?.upperBound != requestedEnd {
            try updateTimeRange(from: startingTime, to: endingTime)
        }

        guard let playbackRange else {
            throw NSError(file: #file, function: #function, description: "invalid edit range")
        }

        lastScheduledTime = audioTime

        let startFrame = AVAudioFramePosition(playbackRange.lowerBound * sampleRate)
        let rangeFrames = AVAudioFramePosition(playbackRange.duration * sampleRate)

        guard rangeFrames > 0 else {
            throw NSError(file: #file, function: #function, description: "Unable to schedule. Range is \(rangeFrames) frames")
        }

        guard let source else {
            throw NSError(file: #file, function: #function, description: "No source is loaded")
        }

        // The previous run is the other consumer of the source, so it has to be gone before this one
        // seeks. **Cancelling is not enough**: cancellation is observed, and a read already inside
        // the decoder stays there until it returns. The generation fence makes that run's callbacks
        // inert but cannot reach a decode under way, so a seek here would rebuild the reader another
        // thread is pulling sample buffers from — a source that permits one consumer, driven by two.
        // Left in place rather than cleared: a second `schedule` landing during the wait below has to
        // find the same task and wait for it too, and `startFeeding` replaces the handle anyway.
        let outgoing = feedTask
        outgoing?.cancel()

        // Newest-only: a signal that arrives while the loop is busy scheduling means "the node took
        // one", and the loop re-reads the count anyway. Queueing them would only make it spin
        // through stale wakeups.
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        // Clears any run already in flight: its completion callbacks are about to arrive and must
        // not refill the queue on this one's behalf. Before the wait below rather than after, so a
        // feed parked on the old signal is released by that signal finishing and does not depend on
        // cancellation alone to wake.
        let generation = feedState.withLock { $0.endRun(replacingSignalWith: continuation) }

        // Bounded by one chunk: the task either returns from its read and exits on the cancellation
        // check, or wakes from the finished signal.
        await outgoing?.value

        // The only suspension point on this path, so a second `schedule` can complete inside it —
        // `TransportPlayer` is `@MainActor`, which serializes the calls but not across an `await`.
        // That call has already taken the source; carrying on would seek underneath it, which is the
        // two-consumer bug this wait exists to prevent.
        guard feedState.withLock({ $0.generation }) == generation else {
            throw NSError(file: #file, function: #function, description: "Superseded by a later schedule")
        }

        let run = Run(
            source: source,
            generation: generation,
            signal: continuation,
            onComplete: onComplete
        )

        currentRun = run
        currentSignals = signals

        // Both on the caller, so a bad seek or an undecodable first packet is *thrown* from
        // `schedule` rather than reported to `eventHandler` after the fact. Everything the caller
        // could still act on should fail this way.
        try source.seek(toFrame: startFrame)

        framesRemaining = rangeFrames
        runAnchor = audioTime

        for _ in 0 ..< Self.prefillBuffers {
            guard try scheduleNextBuffer(run) else { break }
        }

        // The whole range fit in the prefill, so there is nothing left to feed.
        guard framesRemaining > 0 else { return }

        startFeeding(run, signals: signals)
    }

    /// Queues another pass over the current range, after whatever is already scheduled.
    ///
    /// The looping counterpart to ``FilePlayer``'s `scheduleSegment(at: nil)`. `AVAudioPlayerNode`
    /// plays a command with no time immediately after the last one, so a repeat is another pass of
    /// the same frames rather than anything the caller has to time.
    ///
    /// A repeat can arrive after the range has drained and the feed has exited, so this restarts it
    /// when nothing is live.
    public func enqueueRepeat(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil,
        onComplete: (@Sendable () -> Void)? = nil
    ) throws {
        guard let run = currentRun, let signals = currentSignals, let sampleRate else {
            throw NSError(file: #file, function: #function, description: "Nothing is scheduled to repeat")
        }

        let start = startingTime ?? playbackRange?.lowerBound ?? 0
        let end = endingTime ?? playbackRange?.upperBound ?? 0

        guard end > start else {
            throw NSError(file: #file, function: #function, description: "invalid repeat range \(start)...\(end)")
        }

        let shouldStart = feedState.withLock { state -> Bool in
            guard state.generation == run.generation else { return false }

            state.repeatStartFrame = AVAudioFramePosition(start * sampleRate)
            state.repeatRangeFrames = AVAudioFramePosition((end - start) * sampleRate)
            state.pendingRepeats += 1

            guard state.isFeeding == false else { return false }

            state.isFeeding = true
            return true
        }

        guard shouldStart else { return }

        startFeeding(run, signals: signals)
    }
}
