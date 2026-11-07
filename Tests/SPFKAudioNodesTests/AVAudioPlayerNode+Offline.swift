// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation

extension AVAudioPlayerNode {
    /// Queues without awaiting: an offline render consumes the buffer only after the caller returns.
    func enqueue(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime? = nil) {
        scheduleBuffer(buffer, at: when, completionHandler: nil)
    }
}
