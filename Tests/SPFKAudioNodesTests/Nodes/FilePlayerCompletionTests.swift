// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import os
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// Who is told a run finished, when a second run supersedes the first.
///
/// **A real output device, unlike the sibling suites.** `.dataPlayedBack` means the data reached
/// one, so under `.offline` manual rendering these handlers never fire at all — measured: a segment
/// rendered twice over still reported nothing, while the same schedule with `.dataRendered`
/// reported once. A completion test on the offline rig passes without ever running the code it
/// names. The mixer is muted so the run is silent, which the device does not care about.
@Suite(.tags(.engine), .serialized)
final class FilePlayerCompletionTests: TestCaseModel {
    private let sampleRate = FilePlayerTestSupport.sampleRate

    private struct Rig {
        let engine: AVAudioEngine
        let player: FilePlayer

        /// Peak amplitude per tapped buffer, which names the second of the file being played.
        let peaks: OSAllocatedUnfairLock<[Float]>
    }

    private func makeRig(url: URL) throws -> Rig {
        let engine = AVAudioEngine()
        let player = FilePlayer()

        try player.load(url: url)

        guard let format = player.processingFormat else {
            throw NSError(description: "no processing format after load")
        }

        engine.attach(player.playerNode)
        engine.connect(player.playerNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        let peaks = OSAllocatedUnfairLock(initialState: [Float]())

        // On the node rather than the mixer: the mute is downstream of this.
        player.playerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }

            var peak: Float = 0

            for frame in 0 ..< Int(buffer.frameLength) {
                peak = max(peak, abs(channel[frame]))
            }

            peaks.withLock { $0.append(peak) }
        }

        try engine.start()

        return Rig(engine: engine, player: player, peaks: peaks)
    }

    private func teardown(_ rig: Rig, _ url: URL) {
        rig.player.playerNode.removeTap(onBus: 0)
        rig.engine.stop()
        try? FileManager.default.removeItem(at: url)
    }

    /// Polls rather than sleeping a fixed interval: a completion is delivered on the engine's own
    /// schedule, some tens of milliseconds after the audio it reports.
    @discardableResult
    private func wait(
        upTo timeout: TimeInterval = 5,
        for condition: @Sendable () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() { return true }

            try await Task.sleep(for: .milliseconds(20))
        }

        return condition()
    }

    /// A run that a second schedule supersedes reports nothing, and the run that replaced it plays
    /// and reports once.
    ///
    /// Both halves matter: fencing the callbacks while `play()` still cleared the node's queue left
    /// the second run silent and complete before a frame of it had played.
    @Test func aSupersededRunDoesNotReportCompletion() async throws {
        let url = try FilePlayerTestSupport.makeStepFile(seconds: 4)
        let rig = try makeRig(url: url)

        defer { teardown(rig, url) }

        let first = OSAllocatedUnfairLock(initialState: 0)
        let second = OSAllocatedUnfairLock(initialState: 0)

        try rig.player.schedule(from: 0, to: 1) { first.withLock { $0 += 1 } }
        try rig.player.play()

        // The first run is genuinely playing before the second is scheduled.
        let heardFirst = try await wait { rig.peaks.withLock { $0.contains { $0 > 0.05 } } }
        try #require(heardFirst, "the first run never produced audio")

        rig.peaks.withLock { $0.removeAll() }

        try rig.player.schedule(from: 2, to: 3) { second.withLock { $0 += 1 } }
        try rig.player.play()

        let reported = try await wait { second.withLock { $0 } == 1 }
        try #require(reported, "the second run never reported completion")

        #expect(first.withLock { $0 } == 0, "a superseded run reported itself as played to the end")
        #expect(second.withLock { $0 } == 1)

        // The third second of the file, which is what the second run asked for. Anything below this
        // is the first run's tail still draining through the tap.
        let heardSecond = rig.peaks.withLock { $0.contains { $0 > 0.25 } }
        #expect(heardSecond, "the second run never played — its segment was cleared before it started")
    }

    /// The fence does not suppress an ordinary completion.
    @Test func aNaturalCompletionReportsOnce() async throws {
        let url = try FilePlayerTestSupport.makeStepFile(seconds: 2)
        let rig = try makeRig(url: url)

        defer { teardown(rig, url) }

        let count = OSAllocatedUnfairLock(initialState: 0)

        try rig.player.schedule(from: 0, to: 0.3) { count.withLock { $0 += 1 } }
        try rig.player.play()

        let reported = try await wait { count.withLock { $0 } == 1 }
        try #require(reported, "a run that played to its end reported nothing")

        try await Task.sleep(for: .milliseconds(300))

        #expect(count.withLock { $0 } == 1)
    }

    /// A repeat belongs to the run it repeats, so its completion is that run's and is delivered.
    ///
    /// This is what fails if a run is begun for every scheduled segment rather than for every run.
    @Test func aRepeatReportsItsRunsCompletion() async throws {
        let url = try FilePlayerTestSupport.makeStepFile(seconds: 2)
        let rig = try makeRig(url: url)

        defer { teardown(rig, url) }

        let firstPass = OSAllocatedUnfairLock(initialState: 0)
        let repeatPass = OSAllocatedUnfairLock(initialState: 0)

        try rig.player.schedule(from: 0, to: 0.3) { firstPass.withLock { $0 += 1 } }
        try rig.player.enqueueRepeat { repeatPass.withLock { $0 += 1 } }
        try rig.player.play()

        let reported = try await wait { repeatPass.withLock { $0 } == 1 }
        try #require(reported, "a queued repeat reported no completion")

        #expect(firstPass.withLock { $0 } == 1)
        #expect(repeatPass.withLock { $0 } == 1)
    }

    /// An explicit stop is still not a completion.
    @Test func anExplicitStopReportsNothing() async throws {
        let url = try FilePlayerTestSupport.makeStepFile(seconds: 4)
        let rig = try makeRig(url: url)

        defer { teardown(rig, url) }

        let count = OSAllocatedUnfairLock(initialState: 0)

        try rig.player.schedule(from: 0, to: 3) { count.withLock { $0 += 1 } }
        try rig.player.play()

        let heard = try await wait { rig.peaks.withLock { $0.contains { $0 > 0.05 } } }
        try #require(heard, "the run never produced audio")

        rig.player.stop()

        try await Task.sleep(for: .milliseconds(400))

        #expect(count.withLock { $0 } == 0)
    }
}
