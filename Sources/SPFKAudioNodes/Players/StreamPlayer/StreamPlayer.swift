// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import os
import SPFKAudioBase
import SPFKAUHost
import SPFKBase

/// Plays decoded PCM pulled from a stream, for audio `AVAudioFile` cannot open.
///
/// The sibling of ``FilePlayer``, and **deliberately the same node underneath**: both drive one
/// `AVAudioPlayerNode`, where `scheduleBuffer` and `scheduleSegment` are two ways to feed its single
/// queue. So a host gets the same sample-accurate `AVAudioTime` start, the same
/// `playerTime(forNodeTime:)` playhead and the same completion callbacks whichever one it holds —
/// which is what makes a second source type tractable rather than a second transport.
///
/// **Nothing here runs on the render thread.** Frames are decoded and scheduled ahead of time by a
/// feed `Task` and the node consumes them in C. That is the reason a Swift decoder is safe behind
/// this and would not be behind an `AVAudioSourceNode` render block, where allocation and ARC
/// traffic are not allowed.
///
/// Matroska is why this exists: AVFoundation cannot open the container, so `AVAudioFile` throws
/// `'fmt?'` and ``FilePlayer`` has nothing to schedule.
open class StreamPlayer: AudioEngineNodeAU, Mixable, @unchecked Sendable {
    // MARK: - Node

    public var avAudioNode: AVAudioNode { playerNode }

    private(set) var playerNode = AVAudioPlayerNode()

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
    private struct FeedState {
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

            return generation
        }
    }

    private let feedState = OSAllocatedUnfairLock(initialState: FeedState())

    /// The one thing driving the source.
    ///
    /// A single task rather than a serial queue: it gives the same "exactly one consumer" guarantee
    /// the decoder needs — by construction, since only one exists at a time — and it is cancellable,
    /// which a queue is not. `stop` and `schedule` cancel it rather than racing it.
    private var feedTask: Task<Void, Never>?

    /// Handed to the feed task at ``schedule(from:to:audioTime:onComplete:)``; touched nowhere else
    /// once a run is under way.
    private var source: (any SeekablePCMSource)?

    /// The run in progress, so ``enqueueRepeat(onComplete:)`` can start another pass over it.
    private var currentRun: Run?
    private var currentSignals: AsyncStream<Void>?

    /// Frames of the current range still to be scheduled. Touched only by the feed task.
    private var framesRemaining: AVAudioFramePosition = 0

    /// The current run's start time, until the first buffer takes it — after which the rest queue
    /// behind with `at: nil`.
    ///
    /// Held here rather than captured by the feed task because `AVAudioTime` is not `Sendable`, and
    /// this class is `@unchecked Sendable` where that value is not.
    private var runAnchor: AVAudioTime?

    // MARK: - Events

    /// Reports a failure that happens *after* scheduling returned.
    ///
    /// ``FilePlayer`` cannot fail this way — it hands the whole segment to the node and any problem
    /// is thrown from `schedule`. A stream is decoded as it plays, so a packet can fail minutes in,
    /// and without this the feed would simply stop: playback goes silent, the playhead keeps
    /// running, and nothing is told. One handler rather than a `failureHandler`/`stallHandler` pair
    /// so the surface does not grow a closure per condition.
    ///
    /// Called from the feed task, on no particular thread.
    public var eventHandler: (@Sendable (StreamPlayerEvent) -> Void)?

    // MARK: - Loaded source

    /// Cached at load so the caller can ask about the source without touching it — it belongs to
    /// the feed queue.
    public private(set) var url: URL?

    public private(set) var duration: TimeInterval?

    public private(set) var processingFormat: AVAudioFormat?

    public var isLoaded: Bool { processingFormat != nil }

    public internal(set) var isPlaying: Bool = false

    public internal(set) var lastScheduledTime: AVAudioTime?

    public var isScheduled: Bool { lastScheduledTime != nil }

    /// The start and end time of the audio to be played, in source time.
    public private(set) var playbackRange: ClosedRange<TimeInterval>?

    public var editedDuration: TimeInterval? { playbackRange?.duration }

    public var sampleRate: Double? { processingFormat?.sampleRate }

    /// - Returns: The current frame while playing, or nil if unavailable.
    ///
    /// The same derivation as ``FilePlayer/currentFrame`` because it is the same node — the playhead
    /// does not know how the queue was filled.
    public var currentFrame: AVAudioFramePosition? {
        guard let engine,
              engine.isRunning,
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return nil
        }

        return max(0, playerTime.sampleTime)
    }

    public var currentTime: TimeInterval? {
        guard let sampleRate, let currentFrame, let playbackRange else { return nil }

        return currentFrame.double / sampleRate + playbackRange.lowerBound
    }

    // MARK: - Mixable

    public var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = newValue }
    }

    public var pan: AUValue {
        get { playerNode.pan }
        set { playerNode.pan = newValue }
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Loading

    /// Takes ownership of `source`.
    ///
    /// - Parameters:
    ///   - source: the stream to play. Handed over rather than shared — it holds a file position,
    ///     so the feed queue must be the only thing driving it from here on.
    ///   - url: what the source is reading, for a caller that identifies a loaded player by file.
    ///   - duration: the source's length. Taken as a parameter because a container states it in its
    ///     header, where the decoded stream only reveals it by being read to the end.
    public func load(source: some SeekablePCMSource, url: URL, duration: TimeInterval) throws {
        // Unconditionally, not `if isPlaying`: a run armed by `schedule` and never played still has
        // a feed task decoding against the outgoing source, and `stop()` cancels before its own
        // `isPlaying` guard for exactly that reason. Taking the shape FilePlayer uses here left the
        // old task reading a source this method is in the middle of replacing.
        stop()

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

    public func unload() {
        if isPlaying {
            stop()
        }

        feedTask?.cancel()
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
        // seeks. Cancellation is observed rather than immediate, but the generation fence below is
        // what actually makes its remaining callbacks inert.
        feedTask?.cancel()
        feedTask = nil

        // Newest-only: a signal that arrives while the loop is busy scheduling means "the node took
        // one", and the loop re-reads the count anyway. Queueing them would only make it spin
        // through stale wakeups.
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        // Clears any run already in flight: its completion callbacks are about to arrive and must
        // not refill the queue on this one's behalf.
        let generation = feedState.withLock { $0.endRun(replacingSignalWith: continuation) }

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

    private func startFeeding(_ run: Run, signals: AsyncStream<Void>) {
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
    private struct Run: Sendable {
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
    private func scheduleNextBuffer(_ run: Run) throws -> Bool {
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

            playerNode.scheduleBuffer(buffer, at: at, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self, feedState.withLock({ $0.generation == generation }) else { return }

                onComplete?()
            }

            // Keep going when another pass is queued; the loop's own check seeks back and refills
            // `framesRemaining`. Returning false here would end the run mid-loop.
            return feedState.withLock { $0.pendingRepeats > 0 }
        }

        let signal = run.signal

        playerNode.scheduleBuffer(buffer, at: at, options: [], completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.feedState.withLock { state in
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

// MARK: - Playback

extension StreamPlayer {
    public func play() throws {
        guard playerNode.engine?.isRunning == true else {
            throw NSError(description: "StreamPlayer.play() Engine isn't running or available - play() canceled for \(url?.lastPathComponent ?? "nil")")
        }

        if isPlaying {
            playerNode.stop()
        }

        // nil means play immediately; the run's start time was given to the first buffer.
        playerNode.play(at: nil)

        isPlaying = true
    }

    /// Stops playback and cancels the run, including any decode already on its way.
    public func stop() {
        // **Cancelled before the `isPlaying` guard, not after.** A run is armed by `schedule` and
        // starts feeding immediately, so a player that was scheduled but never played still has a
        // task decoding and calling `scheduleBuffer`. Returning early there left it running while
        // the host tore the graph down to load the next file — which crashes inside the engine, and
        // looks like a fault in whatever was loaded next rather than in what was left behind.
        feedTask?.cancel()
        feedTask = nil

        guard isPlaying else {
            // Still clear the run, or a stale generation's callbacks outlive it.
            endRun()

            lastScheduledTime = nil
            return
        }

        // Bumped before `playerNode.stop()`, which fires pending completion handlers: without this
        // one of them would be taken for the current run's. Cancelling the task is not enough on its
        // own, since cancellation is observed rather than immediate.
        endRun()

        isPlaying = false
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
    private func endRun() {
        feedState.withLock { _ = $0.endRun(replacingSignalWith: nil) }

        // The run is over, so nothing may repeat it. Left set, `enqueueRepeat` would pass its
        // `currentRun` guard and then quietly do nothing on the generation check.
        currentRun = nil
        currentSignals = nil
    }
}

// MARK: - AudioEngineNode

extension StreamPlayer: AudioEngineNode {
    public var outputNode: AVAudioNode? { playerNode }

    public func detachNodes() throws {
        unload()

        try detachIONodes()
    }
}
