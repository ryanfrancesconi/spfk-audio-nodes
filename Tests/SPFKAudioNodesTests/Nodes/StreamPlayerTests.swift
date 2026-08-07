// Copyright Ryan Francesconi. All Rights Reserved.

import AVFoundation
import Foundation
import os
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// A ramp: sample *n* is *n*, so any frame that comes out of the engine says which frame it is.
///
/// Synthetic rather than a real decoder on purpose. What is under test is the scheduling — that the
/// right frames reach the node, in order, from the position asked for — and a codec in the middle
/// would only add a way for the test to fail for reasons that are not that. The real decoder is
/// exercised where it lives, in `spfk-audio-conversion`.
private final class RampSource: SeekablePCMSource {
    let processingFormat: AVAudioFormat
    let totalFrameCount: AVAudioFramePosition

    private(set) var framePosition: AVAudioFramePosition = 0

    /// How many times ``seek(toFrame:)`` was called, so a test can tell a seek from a rewind that
    /// happened to produce the same samples.
    private(set) var seekCount = 0

    /// How many times ``readNextChunk(into:frameCount:)`` was called. The feed's read-ahead is
    /// counted in *reads*, so this is the quantity the bound is expressed in.
    private(set) var readCount = 0

    /// Makes ``seek(toFrame:)`` fail, standing in for a container that cannot be repositioned.
    var failsSeek = false

    /// Makes the `n`th read fail, standing in for a packet that will not decode partway through a
    /// file. Counted from 1, so `prefillBuffers + 1` is the first read the feed task makes.
    var failsReadNumber: Int?

    init(sampleRate: Double = 44100, frames: AVAudioFramePosition = 44100 * 4) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            fatalError("standard mono format is always constructible")
        }

        processingFormat = format
        totalFrameCount = frames
    }

    func seek(toFrame frame: AVAudioFramePosition) throws {
        seekCount += 1

        if failsSeek {
            throw NSError(domain: "RampSource", code: 1)
        }

        framePosition = max(0, min(frame, totalFrameCount))
    }

    func readNextChunk(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws -> AVAudioFrameCount {
        readCount += 1

        if readCount == failsReadNumber {
            throw NSError(domain: "RampSource", code: 2)
        }

        let available = AVAudioFrameCount(max(0, totalFrameCount - framePosition))
        let written = min(frameCount, available)

        buffer.frameLength = written

        guard written > 0, let channel = buffer.floatChannelData?[0] else { return 0 }

        for index in 0 ..< Int(written) {
            channel[index] = Float(framePosition + AVAudioFramePosition(index))
        }

        framePosition += AVAudioFramePosition(written)

        return written
    }
}

/// Offline manual rendering throughout: it needs no audio hardware and, more usefully, it is
/// deterministic — the engine renders exactly the frames asked for, so "which frame came out" is a
/// question with one answer.
@Suite(.tags(.engine), .serialized)
final class StreamPlayerTests: TestCaseModel {
    private struct Rig {
        let engine: AVAudioEngine
        let player: StreamPlayer
        let format: AVAudioFormat
    }

    private func makeRig(source: RampSource, duration: TimeInterval) throws -> Rig {
        let engine = AVAudioEngine()
        let player = StreamPlayer()
        let format = source.processingFormat

        engine.attach(player.playerNode)

        // Straight to the output rather than through `mainMixerNode`, which applies an equal-power
        // pan law to a mono source and scales the whole ramp by 1/√2. That gain is correct mixer
        // behavior and has nothing to do with what is under test, but it makes every "which frame
        // came out" assertion read as an off-by-a-lot failure.
        engine.connect(player.playerNode, to: engine.outputNode, format: format)

        try player.load(source: source, url: URL(fileURLWithPath: "/tmp/ramp.mka"), duration: duration)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()

        return Rig(engine: engine, player: player, format: format)
    }

    /// Renders `frameCount` frames and returns channel 0.
    private func render(_ rig: Rig, frameCount: AVAudioFrameCount) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: rig.engine.manualRenderingFormat,
            frameCapacity: rig.engine.manualRenderingMaximumFrameCount
        ) else {
            Issue.record("could not allocate a render buffer")
            return []
        }

        var samples: [Float] = []

        while samples.count < Int(frameCount) {
            let wanted = min(
                AVAudioFrameCount(Int(frameCount) - samples.count),
                rig.engine.manualRenderingMaximumFrameCount
            )

            let status = try rig.engine.renderOffline(wanted, to: buffer)

            guard status == .success, let channel = buffer.floatChannelData?[0] else { break }

            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        return samples
    }

    /// The feed runs on its own queue, so a render immediately after `play()` can outrun it. Waits
    /// for the node to actually hold something rather than sleeping a guessed interval.
    private func waitForBuffers(_ player: StreamPlayer) async throws {
        try await wait(for: player.playerNode.isPlaying, timeout: 5)

        // `isPlaying` says the node was started, not that the pump has filled its queue — that runs
        // on the feed queue and is asynchronous by design.
        try await wait(sec: 0.25)
    }

    @Test func playsFromTheStartOfTheSource() async throws {
        let source = RampSource()
        let rig = try makeRig(source: source, duration: 4)

        try await rig.player.schedule(from: 0, to: 4)
        try rig.player.play()

        try await waitForBuffers(rig.player)

        let samples = try render(rig, frameCount: 512)

        try #require(samples.count == 512)

        // The ramp is the frame index, so the first rendered frame states where playback began.
        #expect(samples[0] == 0)
        #expect(samples[128] == 128)
        #expect(samples[511] == 511)
    }

    /// The case a file-backed player gets from `scheduleSegment(startingFrame:)` and a streamed one
    /// has to get from a seek.
    @Test func playsFromAnOffsetStartTime() async throws {
        let source = RampSource()
        let rig = try makeRig(source: source, duration: 4)

        let start: TimeInterval = 1
        let startFrame = Float(start * rig.format.sampleRate)

        try await rig.player.schedule(from: start, to: 4)
        try rig.player.play()

        try await waitForBuffers(rig.player)

        let samples = try render(rig, frameCount: 256)

        try #require(samples.count == 256)

        #expect(source.seekCount == 1)
        #expect(samples[0] == startFrame)
        #expect(samples[255] == startFrame + 255)
    }

    /// More than one buffer's worth, which is the whole point: the pump has to keep the queue fed
    /// across buffer boundaries without dropping or repeating a frame.
    @Test func rendersContinuouslyAcrossManyBuffers() async throws {
        let source = RampSource()
        let rig = try makeRig(source: source, duration: 4)

        try await rig.player.schedule(from: 0, to: 4)
        try rig.player.play()

        try await waitForBuffers(rig.player)

        // Well past `chunkFrames` (8192), so several refills have to have happened.
        let samples = try render(rig, frameCount: 40000)

        try #require(samples.count == 40000)

        // A gap or a repeat at a buffer seam shows up as a break in the ramp, wherever it is.
        let firstBreak = (1 ..< samples.count).first { samples[$0] != samples[$0 - 1] + 1 }

        #expect(firstBreak == nil, "the ramp breaks at frame \(firstBreak ?? -1) — a buffer seam dropped or repeated frames")
    }

    /// The feed must stay **bounded**, not read the file as fast as it can.
    ///
    /// This is the test that was missing, and its absence froze the app. Every other test here uses
    /// a four-second source, which the pump drains in about twenty buffers — so "keeps a second and
    /// a half queued ahead" and "reads the entire file immediately" produce byte-identical output
    /// and both pass. The bound only becomes observable on a source far longer than the queue, which
    /// is why a feature-length `.mkv` was the first thing to show it.
    ///
    /// Measured at the source rather than at the node: how far the decoder has been read is exactly
    /// the question, and it is the thing that grows without limit when the bound fails.
    @Test func readsAheadByABoundedAmountRatherThanDrainingTheSource() async throws {
        // An hour, so an unbounded pump would have to read ~160,000,000 frames before stopping.
        let source = RampSource(frames: 44100 * 3600)
        let rig = try makeRig(source: source, duration: 3600)

        try await rig.player.schedule(from: 0, to: 3600)
        try rig.player.play()

        try await waitForBuffers(rig.player)

        // Nothing has been rendered yet, so the source should be no further along than the queue
        // depth: 8 buffers of 8192 frames. Generous headroom, because the point is the difference
        // between "a fixed lead" and "the whole file", not the exact figure.
        let readAhead = source.framePosition

        #expect(
            readAhead <= 8192 * 16,
            "the pump read \(readAhead) frames ahead of playback — it is draining the source, not leading it"
        )
    }

    @Test func stopEndsPlayback() async throws {
        let source = RampSource()
        let rig = try makeRig(source: source, duration: 4)

        try await rig.player.schedule(from: 0, to: 4)
        try rig.player.play()

        try await waitForBuffers(rig.player)

        #expect(rig.player.isPlaying)

        rig.player.stop()

        #expect(rig.player.isPlaying == false)
        #expect(rig.player.isScheduled == false)
    }

    /// Re-scheduling is how the transport seeks, so the second run must not be served the first
    /// run's queued audio.
    @Test func reschedulingDiscardsTheEarlierRun() async throws {
        let source = RampSource()
        let rig = try makeRig(source: source, duration: 4)

        try await rig.player.schedule(from: 0, to: 4)
        try rig.player.play()

        try await waitForBuffers(rig.player)

        _ = try render(rig, frameCount: 1024)

        rig.player.stop()

        let start: TimeInterval = 2
        let startFrame = Float(start * rig.format.sampleRate)

        try await rig.player.schedule(from: start, to: 4)
        try rig.player.play()

        try await waitForBuffers(rig.player)

        let samples = try render(rig, frameCount: 256)

        try #require(samples.count == 256)

        #expect(samples[0] == startFrame, "the second run was served audio left over from the first")
    }

    // MARK: - Prefill

    /// The reason `schedule` is `async`.
    ///
    /// **Renders with no wait at all**, unlike every other test here — that is the whole assertion.
    /// A host calls `schedule` then `play` back to back, so if scheduling only armed a background
    /// feed the node would be started with an empty queue and the first frames out of it would be
    /// silence. Remove the prefill and this test reads zeros where the ramp should be.
    @Test func schedulingPutsAudioInTheQueueBeforeItReturns() async throws {
        let source = RampSource()
        let rig = try makeRig(source: source, duration: 4)

        try await rig.player.schedule(from: 0, to: 4)
        try rig.player.play()

        let samples = try render(rig, frameCount: 256)

        try #require(samples.count == 256)

        #expect(samples[0] == 0, "the node was started before any audio reached it")
        #expect(samples[255] == 255)
    }

    /// A source that cannot be repositioned fails the *call*, rather than arming a run that will
    /// quietly produce nothing. Doing the seek on the caller is what buys this.
    @Test func schedulingThrowsWhenTheSourceCannotSeek() async throws {
        let source = RampSource()
        source.failsSeek = true

        let rig = try makeRig(source: source, duration: 4)

        await #expect(throws: (any Error).self) {
            try await rig.player.schedule(from: 0, to: 4)
        }
    }

    // MARK: - Failure reporting

    /// The failure a file-backed player cannot have: decoding stops long after `schedule` returned,
    /// so there is no caller left to throw to. Without the event the run would just go silent.
    @Test func aDecodeFailureAfterSchedulingIsReported() async throws {
        let source = RampSource(frames: 44100 * 3600)

        // Past the prefill, so the failure lands in the feed task rather than in `schedule`.
        source.failsReadNumber = StreamPlayer.prefillBuffers + 1

        let rig = try makeRig(source: source, duration: 3600)

        let reported = OSAllocatedUnfairLock(initialState: false)

        rig.player.eventHandler = { event in
            guard case .failed = event else { return }

            reported.withLock { $0 = true }
        }

        try await rig.player.schedule(from: 0, to: 3600)

        try await wait(for: reported.withLock { $0 }, timeout: 5)
    }

    /// The prefill runs on the caller, so a first packet that will not decode is thrown rather than
    /// reported — the distinction the event exists to preserve.
    @Test func aDecodeFailureDuringThePrefillIsThrown() async throws {
        let source = RampSource()
        source.failsReadNumber = 1

        let rig = try makeRig(source: source, duration: 4)

        let reported = OSAllocatedUnfairLock(initialState: false)

        rig.player.eventHandler = { _ in reported.withLock { $0 = true } }

        await #expect(throws: (any Error).self) {
            try await rig.player.schedule(from: 0, to: 4)
        }

        #expect(reported.withLock { $0 } == false, "a failure the caller could catch was reported instead")
    }

    // MARK: - Backpressure

    /// The bug that froze the app, pinned exactly.
    ///
    /// Nothing is playing, so the node consumes nothing, so the feed must park at the queue depth
    /// and stay there. The earlier version bounded its loop on a counter the completion callbacks
    /// decremented *while it ran*, which on an hour-long source meant reading all of it into memory
    /// — 160 million frames instead of these 65,536. The count is exact rather than a ceiling
    /// because "roughly bounded" is what the broken version also looked like at four seconds.
    @Test func theFeedParksAtTheQueueDepthWhileNothingIsConsumed() async throws {
        let source = RampSource(frames: 44100 * 3600)
        let rig = try makeRig(source: source, duration: 3600)

        try await rig.player.schedule(from: 0, to: 3600)

        let depth = StreamPlayer.targetBuffersInFlight

        try await wait(for: source.readCount == depth, timeout: 5)

        // Long enough that a loop still running would be obvious.
        try await wait(sec: 0.5)

        #expect(
            source.readCount == depth,
            "the feed read \(source.readCount) chunks with a full queue — it is draining the source, not leading it"
        )
    }

    /// The other half: parking must not be stalling. Once the node takes buffers, the feed has to
    /// wake and refill — which is what the completion handler's signal is for.
    @Test func theFeedResumesWhenTheNodeConsumes() async throws {
        let source = RampSource(frames: 44100 * 3600)
        let rig = try makeRig(source: source, duration: 3600)

        try await rig.player.schedule(from: 0, to: 3600)

        let depth = StreamPlayer.targetBuffersInFlight

        try await wait(for: source.readCount == depth, timeout: 5)

        try rig.player.play()

        // Four buffers' worth, so several have to be consumed and replaced.
        _ = try render(rig, frameCount: StreamPlayer.chunkFrames * 4)

        try await wait(for: source.readCount > depth, timeout: 5)
    }

    /// Stopping has to end the feed, not leave a task decoding into a node that will never play it.
    @Test func stopEndsTheFeed() async throws {
        let source = RampSource(frames: 44100 * 3600)
        let rig = try makeRig(source: source, duration: 3600)

        try await rig.player.schedule(from: 0, to: 3600)
        try rig.player.play()

        _ = try render(rig, frameCount: StreamPlayer.chunkFrames * 2)

        rig.player.stop()

        let atStop = source.readCount

        try await wait(sec: 0.5)

        #expect(source.readCount == atStop, "the feed kept decoding after stop()")
    }

    /// A source that runs out inside the requested range ends the run rather than stalling it — a
    /// container states a segment length, not an audio track length, so a short read is ordinary.
    @Test func endsWhenTheSourceRunsOut() async throws {
        let source = RampSource(frames: 20000)
        let rig = try makeRig(source: source, duration: 4)

        try await rig.player.schedule(from: 0, to: 4)
        try rig.player.play()

        try await waitForBuffers(rig.player)

        let samples = try render(rig, frameCount: 30000)

        try #require(samples.count == 30000)

        // Everything the source had, then silence — not a repeat of the last buffer.
        #expect(samples[19999] == 19999)
        #expect(samples[20000] == 0)
        #expect(samples[25000] == 0)
    }
}
