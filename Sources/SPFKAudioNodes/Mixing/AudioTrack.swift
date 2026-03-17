// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAUHost
import SPFKBase

/// A track containing a mixer input, fader output, and an effects chain.
///
/// Isolated to `@MainActor` — all access originates from `@MainActor AudioWorkspace`.
/// Protocol conformances to `AudioUnitChainDelegate` and `AudioEngineNode` use
/// `@preconcurrency` because those protocols aren't `@MainActor`-qualified and
/// delegate callbacks arrive from the `AudioUnitChain` actor. `AVAudioNode`
/// parameters crossing isolation boundaries use `nonisolated(unsafe)` bindings.
@MainActor
public final class AudioTrack {
    /// input
    public let mixer: MixerWrapper

    /// output
    public let fader: Fader
    
    public var gain: AUValue {
        get { fader.gain }
        set { fader.gain = newValue }
    }

    /// effects
    public private(set) lazy var audioUnitChain: AudioUnitChain = .init(delegate: self)

    public let delegate: AudioTrackDelegate?

    public init(delegate: AudioTrackDelegate?) async throws {
        self.delegate = delegate

        mixer = MixerWrapper()
        fader = try await Fader()

        nonisolated(unsafe) let inputNode = mixer.avAudioNode
        nonisolated(unsafe) let outputNode = fader.avAudioNode
        try await audioUnitChain.updateIO(input: inputNode, output: outputNode)
    }

    deinit {
        Log.debug("- { \(self) }")
    }
}

extension AudioTrack: @preconcurrency AudioUnitChainDelegate {
    public func connectAndAttach(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) async throws {
        nonisolated(unsafe) let n1 = node1
        nonisolated(unsafe) let n2 = node2
        try await delegate?.connectAndAttach(n1, to: n2, format: format)

        Log.debug("Connected", n1, "to", n2, "with format", format?.readableDescription)
    }

    public func audioUnitChain(_ audioUnitChain: AudioUnitChain, event: AudioUnitChainEvent) async {
        await delegate?.audioUnitChain(audioUnitChain, event: event)
    }

    public var availableAudioUnitComponents: [AVAudioUnitComponent]? {
        guard let delegate else {
            assertionFailure("delegate is nil")
            return []
        }

        return delegate.availableAudioUnitComponents
    }

    public var audioUnitManufacturerCollection: [AudioUnitManufacturerCollection] {
        guard let delegate else {
            assertionFailure("delegate is nil")
            return []
        }

        return delegate.audioUnitManufacturerCollection
    }
}

extension AudioTrack: @preconcurrency AudioEngineNode {
    public var inputNode: AVAudioNode? { mixer.avAudioNode }
    public var outputNode: AVAudioNode? { fader.avAudioNode }
}

public protocol AudioTrackDelegate: AnyObject, AudioUnitChainDelegate {}
