// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// `enqueueRepeat` has to answer the same way on both conformers of ``TransportSourcePlayer``, and
/// the range it is given is not the player's range — a run can begin inside a loop.
@Suite(.tags(.engine), .serialized)
final class FilePlayerRepeatTests: TestCaseModel {
    private let sampleRate = FilePlayerTestSupport.sampleRate

    private struct Rig {
        let engine: AVAudioEngine
        let player: FilePlayer
    }

    private func makeRig(url: URL) throws -> Rig {
        let engine = AVAudioEngine()
        let player = FilePlayer()

        try player.load(url: url)

        guard let format = player.processingFormat else {
            throw NSError(description: "no processing format after load")
        }

        engine.attach(player.playerNode)
        engine.connect(player.playerNode, to: engine.outputNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()

        return Rig(engine: engine, player: player)
    }

    private func render(_ rig: Rig, frameCount: AVAudioFrameCount) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: rig.engine.manualRenderingFormat,
            frameCapacity: rig.engine.manualRenderingMaximumFrameCount
        ) else {
            throw NSError(description: "could not allocate a render buffer")
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

    /// With no arguments a repeat plays the range again — not the whole file.
    @Test func repeatWithNoArgumentsKeepsTheTrimmedRange() async throws {
        let url = try FilePlayerTestSupport.makeStepFile(seconds: 4)
        let rig = try makeRig(url: url)

        // The third second only.
        try rig.player.schedule(from: 2, to: 3)
        try rig.player.enqueueRepeat()
        try rig.player.play()

        let samples = try render(rig, frameCount: AVAudioFrameCount(sampleRate * 2))

        try #require(samples.count == Int(sampleRate * 2))

        #expect(samples[0] == FilePlayerTestSupport.step(2))

        // The second pass, which used to begin at the top of the file.
        #expect(samples[Int(sampleRate) + 16] == FilePlayerTestSupport.step(2), "the repeat played a range other than the one that was set")

        rig.engine.stop()
        try? FileManager.default.removeItem(at: url)
    }

    /// A repeat is a span to play, not a redefinition of the player's range.
    @Test func repeatDoesNotRedefineThePlaybackRange() async throws {
        let url = try FilePlayerTestSupport.makeStepFile(seconds: 4)
        let rig = try makeRig(url: url)

        try rig.player.schedule(from: 1, to: 2)

        let before = try #require(rig.player.playbackRange)

        try rig.player.enqueueRepeat(from: 0, to: 4)

        #expect(rig.player.playbackRange == before, "enqueueRepeat moved the range currentTime is measured against")

        rig.engine.stop()
        try? FileManager.default.removeItem(at: url)
    }

    /// A queued repeat carries no start time of its own, which is not the same as nothing being
    /// scheduled.
    @Test func repeatLeavesThePlayerScheduled() async throws {
        let url = try FilePlayerTestSupport.makeStepFile(seconds: 4)
        let rig = try makeRig(url: url)

        try rig.player.schedule(from: 0, to: 1)

        #expect(rig.player.isScheduled)

        try rig.player.enqueueRepeat()

        #expect(rig.player.isScheduled, "the player reported itself unscheduled after queueing a repeat")

        rig.engine.stop()
        try? FileManager.default.removeItem(at: url)
    }
}
