// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

@Suite(.tags(.engine), .serialized)
final class FilePlayerRangeTests: TestCaseModel {
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

    /// Out-of-range bounds clamp to the file; an inverted range throws.
    @Test func scheduleClampsThePlaybackRange() throws {
        let url = TestBundleResources.shared.tabla_wav
        let rig = try makeRig(url: url)
        let player = rig.player

        defer { rig.engine.stop() }

        let file = try AVAudioFile(forReading: url)
        let duration = try #require(player.duration)
        #expect(duration == Double(file.length) / file.fileFormat.sampleRate)

        try player.schedule()
        #expect(player.playbackRange == 0 ... duration)
        #expect(player.editedDuration == duration)

        try player.schedule(from: 0, to: duration)
        #expect(player.playbackRange == 0 ... duration)

        try player.schedule(from: 0)
        #expect(player.playbackRange == 0 ... duration)

        try player.schedule(from: duration - 1)
        #expect(player.playbackRange == duration - 1 ... duration)
        #expect(player.editedDuration == 1)

        try player.schedule(to: 3)
        #expect(player.playbackRange == 0 ... 3)
        #expect(player.editedDuration == 3)

        try player.schedule(from: 1, to: 3)
        #expect(player.playbackRange == 1 ... 3)
        #expect(player.editedDuration == 2)

        #expect(throws: (any Error).self) {
            try player.schedule(from: 4, to: 3)
        }

        try player.schedule(from: 0, to: duration + 1)
        #expect(player.playbackRange == 0 ... duration)

        try player.schedule(from: -1, to: duration)
        #expect(player.playbackRange == 0 ... duration)
    }

    @Test func isPlayingFollowsPlayAndStop() throws {
        let rig = try makeRig(url: TestBundleResources.shared.tabla_wav)
        let player = rig.player

        defer { rig.engine.stop() }

        try player.schedule(from: 1, to: 3)
        try player.play()
        #expect(player.isPlaying)

        player.stop()
        #expect(!player.isPlaying)
    }
}
