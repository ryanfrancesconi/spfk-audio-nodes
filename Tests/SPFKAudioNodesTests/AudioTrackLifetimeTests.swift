// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAUHost
import Testing

@testable import SPFKAudioNodes

/// A track points back at the object that made it, and the chain it owns points back at the track.
/// Both are `weak`, so releasing the host releases the whole graph.
@MainActor
@Suite struct AudioTrackLifetimeTests {
    final class Host: AudioTrackDelegate, @unchecked Sendable {
        func audioUnitChain(_ audioUnitChain: AudioUnitChain, event: AudioUnitChainEvent) async {}

        func connectAndAttach(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) async throws {}

        var availableAudioUnitComponents: [AVAudioUnitComponent]? { [] }

        var audioUnitManufacturerCollection: [AudioUnitManufacturerCollection] { [] }
    }

    @Test func theTrackAndItsHostAreFreedTogether() async throws {
        weak var weakTrack: AudioTrack?
        weak var weakHost: Host?

        try await {
            let host = Host()
            let track = try await AudioTrack(delegate: host)
            _ = track.audioUnitChain
            weakTrack = track
            weakHost = host
        }()

        #expect(weakTrack == nil)
        #expect(weakHost == nil)
    }

    /// A weak delegate whose target nothing else retains dies on assignment. The host outlives the
    /// track here, so both back-references survive construction.
    @Test func theTrackAndChainStillReachTheirDelegates() async throws {
        let host = Host()
        let track = try await AudioTrack(delegate: host)

        #expect(track.delegate === host)

        let chainDelegate = await track.audioUnitChain.delegate
        #expect(chainDelegate === track)
    }
}
