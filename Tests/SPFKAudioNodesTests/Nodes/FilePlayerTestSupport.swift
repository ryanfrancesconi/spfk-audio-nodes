// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKBase

/// Shared fixture for the ``FilePlayer`` suites.
enum FilePlayerTestSupport {
    static let sampleRate: Double = 44100

    /// One second per step, each at its own amplitude, so a rendered sample says which second of
    /// the file it came from without depending on how a format rounds a ramp.
    static func makeStepFile(seconds: Int) throws -> URL {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(description: "standard mono format is always constructible")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).caf")

        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        for second in 0 ..< seconds {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate)
            ) else {
                throw NSError(description: "could not allocate a step buffer")
            }

            buffer.frameLength = AVAudioFrameCount(sampleRate)

            let value = step(second)

            for frame in 0 ..< Int(sampleRate) {
                buffer.floatChannelData?[0][frame] = value
            }

            try file.write(from: buffer)
        }

        return url
    }

    /// The amplitude written for `second` by ``makeStepFile(seconds:)``.
    static func step(_ second: Int) -> Float {
        Float(second + 1) / 10
    }
}
