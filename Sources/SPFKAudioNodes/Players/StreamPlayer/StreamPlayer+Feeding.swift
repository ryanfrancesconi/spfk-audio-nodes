// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import os
import SPFKAudioBase
import SPFKAUHost
import SPFKBase

extension StreamPlayer {
    // MARK: - Feeding

    /// Frames per scheduled buffer.
    ///
    /// Read cost per trip against how finely playback can be stopped — the node keeps whole buffers,
    /// so this is also the granularity at which a range end can land.
    static let chunkFrames: AVAudioFrameCount = 8192

    /// How many buffers to keep queued ahead of the playhead.
    ///
    /// Roughly 1.5 seconds at 44.1kHz, which is the lead time that has to survive a stalled feed
    /// queue without a dropout. Stated as a constant rather than tuned by feel so that a dropout
    /// report has a number to move.
    static let targetBuffersInFlight = 8

    /// How many buffers ``schedule(from:to:audioTime:onComplete:)`` queues before it returns.
    ///
    /// The reason that method is `async`. A host calls `schedule` and then `play` back to back, so
    /// if scheduling only *armed* a background feed the node could be told to start with nothing in
    /// its queue — it would render silence until the first buffer landed, and that buffer carries
    /// the run's start time, so it would be stamped with a moment already past. Awaiting a prefill
    /// makes "scheduled" mean the audio is there, which is what the caller already assumed.
    static let prefillBuffers = 2

    /// Shared between the caller and the feed task.
    ///
    /// An unfair lock rather than an actor hop because it is read from the node's `@Sendable`
    /// completion handlers, which arrive on arbitrary threads and cannot await.
    struct FeedState {
        /// Bumped by every `schedule` and `stop`, so a superseded run's callbacks cannot be
        /// mistaken for the current one's.
        var generation: Int = 0

        var buffersInFlight: Int = 0

        /// Yielded to by each buffer's completion handler, awaited by the feed loop.
        ///
        /// Held here rather than as a bare property because the handlers fire on arbitrary threads
        /// while `stop` finishes it from the caller's.
        var signal: AsyncStream<Void>.Continuation?

        /// Passes over the range still to be made, beyond the one under way.
        var pendingRepeats: Int = 0

        /// What a repeat plays. Not the run's own range: playback can begin inside a loop, and that
        /// first partial pass is not what repeats. Held here rather than on `Run` because the feed
        /// task is already holding a `Run` by value when the range is stated.
        var repeatStartFrame: AVAudioFramePosition = 0
        var repeatRangeFrames: AVAudioFramePosition = 0

        /// Whether a feed task is live. A repeat queued after the range drained has to start one.
        var isFeeding = false

        /// Fences the current run's callbacks and drops everything scoped to it.
        ///
        /// Both `schedule` and `stop` end a run and differ only in what replaces the signal, so
        /// this is one definition rather than two blocks that have to be kept in step — the
        /// queued repeats used to be cleared by neither, and survived into the following run.
        ///
        /// - Returns: the new generation.
        mutating func endRun(replacingSignalWith newSignal: AsyncStream<Void>.Continuation?) -> Int {
            generation += 1
            buffersInFlight = 0

            signal?.finish()
            signal = newSignal

            pendingRepeats = 0
            repeatStartFrame = 0
            repeatRangeFrames = 0

            // The outgoing task clears this only for its own generation, which has just moved, so
            // a superseded run would otherwise leave it set with nothing feeding — and
            // `enqueueRepeat` refuses to start a feed while it is.
            isFeeding = false

            return generation
        }
    }

    func startFeeding(_ run: Run, signals: AsyncStream<Void>) {
        feedState.withLock { $0.isFeeding = true }

        feedTask = Task(priority: .userInitiated) { [weak self] in
            await self?.feed(run, signals: signals)

            // Only this run's task may clear the flag. A superseded one exiting after a newer run
            // started would otherwise report the live feed as idle, and `enqueueRepeat` would
            // start a second task against a source that allows exactly one consumer.
            self?.feedState.withLock { state in
                guard state.generation == run.generation else { return }

                state.isFeeding = false
            }
        }
    }

    /// What one scheduling run needs, so the feed task takes a single `Sendable` value rather than
    /// five loose parameters.
    struct Run: Sendable {
        let source: any SeekablePCMSource
        let generation: Int
        let signal: AsyncStream<Void>.Continuation
        let onComplete: (@Sendable () -> Void)?
    }

    /// Decodes and schedules the run, keeping ``targetBuffersInFlight`` queued ahead of the playhead
    /// until the range is spent.
    ///
    /// **Bounded by waiting, not by counting.** The loop hands back its thread whenever the node's
    /// queue is full, so it cannot spin — and it cannot run away either. An earlier version looped
    /// on `buffersInFlight < target` alone, which the consumption callbacks decrement *while the
    /// loop is running*: the ceiling moved out from under it and one call read the entire file,
    /// allocating a buffer per 8192 frames. On a four-second fixture that drains in twenty buffers
    /// and is indistinguishable from correct behavior; on a feature film it froze the app.
    ///
    /// One task per run, so the source has exactly one consumer — the guarantee a serial queue used
    /// to provide, now held by construction and cancellable with it.
    private func feed(_ run: Run, signals: AsyncStream<Void>) async {
        var consumptions = signals.makeAsyncIterator()

        while Task.isCancelled == false {
            let state = feedState.withLock { $0 }

            guard state.generation == run.generation else { return }

            if framesRemaining <= 0 {
                let next = feedState.withLock { pending -> (AVAudioFramePosition, AVAudioFramePosition)? in
                    guard pending.pendingRepeats > 0 else { return nil }

                    pending.pendingRepeats -= 1
                    return (pending.repeatStartFrame, pending.repeatRangeFrames)
                }

                guard let (repeatStart, repeatFrames) = next else { return }

                do {
                    try run.source.seek(toFrame: repeatStart)
                } catch {
                    run.signal.finish()
                    eventHandler?(.failed(error))
                    return
                }

                framesRemaining = repeatFrames
            }

            guard state.buffersInFlight < Self.targetBuffersInFlight else {
                // The node has all the lead it wants. Wait for it to say it took one — the stream
                // finishes on stop, so this cannot outlive the run.
                guard await consumptions.next() != nil else { return }
                continue
            }

            do {
                guard try scheduleNextBuffer(run) else { return }

            } catch {
                // Minutes into a file, with the caller long since returned from `schedule` — the
                // only way to say so is the event handler.
                run.signal.finish()
                eventHandler?(.failed(error))
                return
            }
        }
    }

    /// Decodes one chunk and hands it to the node.
    ///
    /// - Returns: `false` when the run is finished — either the range is spent or the source ended
    ///   inside it, which is ordinary: a container states a segment length, not a track length.
    ///
    /// The one place a buffer is created and scheduled, so the prefill on the caller's thread and
    /// the feed task cannot drift apart in how they count frames or stamp the anchor. They never
    /// run at the same time: the task is only started once the prefill has returned.
    @discardableResult
    func scheduleNextBuffer(_ run: Run) throws -> Bool {
        guard let format = processingFormat, framesRemaining > 0 else { return false }

        let wanted = AVAudioFrameCount(min(framesRemaining, AVAudioFramePosition(Self.chunkFrames)))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else {
            throw NSError(file: #file, function: #function, description: "Could not allocate a \(wanted) frame buffer")
        }

        let written = try run.source.readNextChunk(into: buffer, frameCount: wanted)

        guard written > 0 else {
            // The source ended on a buffer boundary, so the short read below never came. Nothing to
            // schedule, but a queued repeat still has to be taken.
            framesRemaining = 0

            return feedState.withLock { $0.pendingRepeats > 0 }
        }

        framesRemaining -= AVAudioFramePosition(written)

        // A short read is the source ending inside the declared range: Matroska rounds a segment
        // duration to its TimecodeScale, so a lossless track falls short of it by up to a
        // millisecond. Without this the last buffer never counts as last — its completion does not
        // fire, and a queued repeat is never taken.
        if written < wanted {
            framesRemaining = 0
        }

        // The anchor is the run's start time and belongs to whichever buffer goes in first;
        // everything after it queues behind with `at: nil`.
        let at = runAnchor
        runAnchor = nil

        feedState.withLock { $0.buffersInFlight += 1 }

        let generation = run.generation
        let isLast = framesRemaining <= 0

        if isLast {
            // `.dataPlayedBack` rather than `.dataConsumed`: completion means the audience has
            // heard it, where consumption only means the node has read it out of the buffer.
            let onComplete = run.onComplete

            // **Captures the lock, not the player.** A completion handler runs on the node's own
            // serial callback queue, and a strong reference taken there — including the transient
            // one `guard let self` or `self?.` creates — can be the last one: releasing it
            // deallocates the `AVAudioPlayerNode` from inside its own callback, and that dealloc's
            // `Stop` dispatches synchronously to the queue it is already on. `feedState` is a
            // `Sendable` value that fences the run on its own, so nothing here needs the player.
            playerNode.scheduleBuffer(buffer, at: at, options: [], completionCallbackType: .dataPlayedBack) { [feedState] _ in
                guard feedState.withLock({ $0.generation == generation }) else { return }

                onComplete?()
            }

            // Keep going when another pass is queued; the loop's own check seeks back and refills
            // `framesRemaining`. Returning false here would end the run mid-loop.
            return feedState.withLock { $0.pendingRepeats > 0 }
        }

        let signal = run.signal

        playerNode.scheduleBuffer(buffer, at: at, options: [], completionCallbackType: .dataConsumed) { [feedState] _ in
            feedState.withLock { state in
                guard state.generation == generation else { return }

                state.buffersInFlight = max(0, state.buffersInFlight - 1)
            }

            // Only ever a wakeup. Scheduling from inside a completion handler is what
            // `AVAudioPlayerNode.h` warns has to be serialized against everything else, and the feed
            // task is where that happens.
            signal.yield()
        }

        return true
    }
}
