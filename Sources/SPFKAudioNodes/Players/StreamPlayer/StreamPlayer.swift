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

    let feedState = OSAllocatedUnfairLock(initialState: FeedState())

    /// The one thing driving the source.
    ///
    /// A single task rather than a serial queue: it gives the same "exactly one consumer" guarantee
    /// the decoder needs — by construction, since only one exists at a time — and it is cancellable,
    /// which a queue is not. `stop` and `schedule` cancel it rather than racing it.
    var feedTask: Task<Void, Never>?

    /// Handed to the feed task at ``schedule(from:to:audioTime:onComplete:)``; touched nowhere else
    /// once a run is under way.
    var source: (any SeekablePCMSource)?

    /// The run in progress, so ``enqueueRepeat(onComplete:)`` can start another pass over it.
    var currentRun: Run?
    var currentSignals: AsyncStream<Void>?

    /// Frames of the current range still to be scheduled. Touched only by the feed task.
    var framesRemaining: AVAudioFramePosition = 0

    /// The current run's start time, until the first buffer takes it — after which the rest queue
    /// behind with `at: nil`.
    ///
    /// Held here rather than captured by the feed task because `AVAudioTime` is not `Sendable`, and
    /// this class is `@unchecked Sendable` where that value is not.
    var runAnchor: AVAudioTime?

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
    public internal(set) var url: URL?

    public internal(set) var duration: TimeInterval?

    public internal(set) var processingFormat: AVAudioFormat?

    public var isLoaded: Bool { processingFormat != nil }

    /// Told to play and not since stopped, whatever the engine is doing.
    ///
    /// Everything inside this class reads this rather than ``isPlaying``, for the same reason
    /// ``FilePlayer`` does: the engine can stop underneath a player, and a `stop()` guarded on
    /// "is audio flowing" would then never clear the latch or cancel the feed.
    public internal(set) var isPlaybackArmed: Bool = false

    /// Whether audio is actually being produced.
    public var isPlaying: Bool {
        isPlaybackArmed && playerNode.engine?.isRunning == true
    }

    public internal(set) var lastScheduledTime: AVAudioTime?

    public var isScheduled: Bool { lastScheduledTime != nil }

    /// The start and end time of the audio to be played, in source time.
    public internal(set) var playbackRange: ClosedRange<TimeInterval>?

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

    /// Supersedes the run, so a handler that outlives the player cannot deliver its `onComplete`.
    ///
    /// The node does outlive it whenever an engine still holds it: the queued buffers are destroyed
    /// later, and destroying them calls the handlers — which hold the generation rather than the
    /// player. ``FilePlayer`` fences the same ordering, and its completion suite pins the behavior.
    deinit {
        feedState.withLock { _ = $0.endRun(replacingSignalWith: nil) }
    }
}

// MARK: - AudioEngineNode

extension StreamPlayer: AudioEngineNode {
    public var outputNode: AVAudioNode? { playerNode }

    public func detachNodes() async throws {
        await unload()

        try detachIONodes()
    }
}
