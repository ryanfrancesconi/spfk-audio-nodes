// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAUHost

extension Metronome: AudioEngineNodeAU {
    public var avAudioNode: AVAudioNode { sourceNode }
}

extension Metronome: AudioEngineNode {
    public var outputNode: AVAudioNode? { sourceNode }
}

// MARK: - Mixable

extension Metronome: Mixable {
    public var volume: Float {
        get { sourceNode.volume }
        set { sourceNode.volume = newValue }
    }

    public var pan: Float {
        get { sourceNode.pan }
        set { sourceNode.pan = newValue }
    }
}
