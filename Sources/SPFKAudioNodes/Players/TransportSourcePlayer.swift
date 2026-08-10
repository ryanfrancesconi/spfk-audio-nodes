// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAUHost

/// What a transport needs from the thing it is playing, so that it does not need to know whether
/// the audio came out of a file or a stream.
///
/// Two conformers, and the split is exactly one question — can `AVAudioFile` open it:
/// ``FilePlayer`` schedules segments of a file, ``StreamPlayer`` schedules buffers pulled from a
/// decoder. **Both drive an `AVAudioPlayerNode`**, so everything below the seam — the sample-accurate
/// `AVAudioTime` start, the `playerTime(forNodeTime:)` playhead, the completion callbacks — is the
/// same machinery rather than two implementations of it.
///
/// Deliberately narrow. It is the surface `TransportPlayer` already used against `FilePlayer` and
/// not a general player abstraction; anything wider would have to be honored twice.
/// `Sendable` because scheduling suspends, so a `@MainActor` host holding one as an existential has
/// to be able to carry it across that suspension. Both conformers already declare
/// `@unchecked Sendable` on the same terms — access is serial, one context drives a player at a
/// time — so this states on the protocol what both types had stated separately.
public protocol TransportSourcePlayer: AudioEngineNode, Mixable, Sendable {
    /// What is loaded, for a host that identifies a loaded player by file.
    var url: URL? { get }

    /// The full length of the loaded source, independent of any range set on it.
    var duration: TimeInterval? { get }

    var isLoaded: Bool { get }

    /// Whether audio is actually being produced — false once the engine stops, however it stopped.
    var isPlaying: Bool { get }

    /// Told to play and not since stopped, whatever the engine is doing.
    ///
    /// AVFoundation stops the engine on a configuration change without telling either player, so
    /// by the time a host reacts ``isPlaying`` is already false. This is what still says playback
    /// was live, and is how a host decides whether to resume once the engine is back.
    var isPlaybackArmed: Bool { get }

    var isScheduled: Bool { get }

    /// The time the current run was scheduled to start at, or nil when nothing is scheduled.
    var lastScheduledTime: AVAudioTime? { get }

    /// The format the node renders. A player renders one format for its lifetime, so a host caching
    /// players keys them on this.
    var processingFormat: AVAudioFormat? { get }

    var currentTime: TimeInterval? { get }

    /// The portion of the source to play — the trim or loop window, not the whole file.
    var playbackRange: ClosedRange<TimeInterval>? { get }

    func updateTimeRange(from startingTime: TimeInterval?, to endingTime: TimeInterval?) throws

    /// Schedules a run starting `scheduledTime` seconds after `hostTime`.
    ///
    /// **`async` for the one conformer that needs it.** ``FilePlayer`` hands the node a segment of
    /// an open file and is done; ``StreamPlayer`` has to decode before there is anything to hand
    /// over, and a host that calls `schedule` then `play` would otherwise start a node with an
    /// empty queue. Swift lets `FilePlayer`'s synchronous methods satisfy these requirements
    /// unchanged, so the cost of the distinction falls on the type that has it.
    func schedule(
        from startingTime: TimeInterval?,
        to endingTime: TimeInterval?,
        when scheduledTime: TimeInterval,
        hostTime: UInt64?,
        onComplete: (@Sendable () -> Void)?
    ) async throws

    /// Schedules a run starting at an absolute time, which is how a host lines several sources up on
    /// one clock.
    func schedule(
        from startingTime: TimeInterval?,
        to endingTime: TimeInterval?,
        audioTime: AVAudioTime,
        onComplete: (@Sendable () -> Void)?
    ) async throws

    /// Queues a pass over `startingTime...endingTime`, after whatever is already scheduled.
    ///
    /// How a loop iterates. `AVAudioPlayerNode` plays a command with no time immediately after the
    /// last one, so neither conformer has to time anything against a clock — which is also why this
    /// works in manual rendering mode, where host time is ignored.
    ///
    /// **The range is stated rather than reused**: playback can begin inside a loop, and that first
    /// partial pass is not what repeats.
    func enqueueRepeat(
        from startingTime: TimeInterval?,
        to endingTime: TimeInterval?,
        onComplete: (@Sendable () -> Void)?
    ) throws

    func play() throws

    func stop()

    /// Releases what is loaded and everything reading it.
    ///
    /// **`async` for the same conformer `schedule` is async for.** ``StreamPlayer`` owns a feed task
    /// that may be inside a blocking decode, and only awaiting it ends that read — `stop()` cancels,
    /// which is observed rather than immediate. ``FilePlayer`` has nothing in flight and satisfies
    /// this with its synchronous body unchanged.
    func unload() async
}

// MARK: - Conformances

/// Both are declared here rather than at each type, so the two stay answerable side by side: the
/// protocol is the list of things `TransportPlayer` does to whatever it is holding, and a member
/// that only one of them can honor does not belong in it.
extension FilePlayer: TransportSourcePlayer {}

extension StreamPlayer: TransportSourcePlayer {}
