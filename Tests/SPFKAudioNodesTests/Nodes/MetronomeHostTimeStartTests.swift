// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// A metronome started at a host time hears its start beat at that time: after a silence when the
/// time is ahead, and joined on its grid when the time has passed. Runs on the output device, silenced.
@Suite(.tags(.hardware, .engine), .serialized)
final class MetronomeHostTimeStartTests: TestCaseModel {
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var blocks: [(hostTime: UInt64, samples: [Float])] = []
    }

    /// Seconds from now to the requested host time: ahead, and already passed.
    @Test(arguments: [0.2, -0.3])
    func startBeatIsHeardAtItsHostTime(secondsFromNow: Double) async throws {
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let soundSet = try MetronomeSoundSet.drums()
        let metronome = Metronome(soundSet: soundSet, sampleRate: sampleRate)
        metronome.bpm = Bpm(120)

        // The render block's own format: the source node's default output format is 44.1 kHz.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        engine.attach(metronome.sourceNode)
        engine.connect(metronome.sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        let capture = Capture()
        metronome.sourceNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, time in
            guard time.isHostTimeValid, let data = buffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            capture.lock.withLock { capture.blocks.append((time.hostTime, samples)) }
        }

        try engine.start()
        defer {
            metronome.sourceNode.removeTap(onBus: 0)
            engine.stop()
        }

        try await Task.sleep(for: .milliseconds(300))

        // Beat 1 of a 4/4 bar is heard at the host time, then a beat every 0.5 s. Each sample's
        // onset sits a fraction of a millisecond in, and the bar's downbeat has its own.
        let threshold: Float = 0.05
        let beatOnset = try #require(Self.firstIndex(above: threshold, in: soundSet.beat))
        let barOnset = try #require(Self.firstIndex(above: threshold, in: soundSet.bar))
        let calledAt = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let startSeconds = calledAt + secondsFromNow
        metronome.play(fromBeat: 1, atHostTime: AVAudioTime.hostTime(forSeconds: startSeconds))

        try await Task.sleep(for: .seconds(1.4))
        metronome.stop()

        let blocks = capture.lock.withLock { capture.blocks }

        // The beats due after the call; one already passed stays unheard.
        let expected: [Double] = (1 ... 4)
            .map { (beat: Int) -> Double in
                let onset = beat % 4 == 0 ? barOnset : beatOnset
                return startSeconds + Double(beat - 1) * 0.5 + Double(onset) / sampleRate
            }
            .filter { $0 > calledAt + 0.05 && $0 < calledAt + 1.3 }
        let deviations = expected.map { time in
            Self.firstOnset(in: blocks, above: threshold, near: time, sampleRate: sampleRate).map { ($0 - time) * 1000 } ?? .infinity
        }
        let firstSound = Self.firstOnset(in: blocks, above: threshold, near: calledAt, within: 2, sampleRate: sampleRate)

        print(
            "METRONOME-HOST-START \(secondsFromNow) s from now, at \(sampleRate) Hz:",
            "deviations ms \(deviations.map { String(format: "%.3f", $0) })",
            "first sound \(firstSound.map { String(format: "%.1f ms after the call", ($0 - calledAt) * 1000) } ?? "none")"
        )

        #expect(expected.count >= 2)
        #expect(deviations.allSatisfy { abs($0) < 0.2 })
        // Nothing sounds before the first beat due: no click from the top of the grid at the call.
        let firstDue = try #require(expected.first)
        #expect(abs(((firstSound ?? .infinity) - firstDue) * 1000) < 0.2)
    }

    private static func firstIndex(above threshold: Float, in buffer: AVAudioPCMBuffer) -> Int? {
        guard let data = buffer.floatChannelData else { return nil }
        return (0 ..< Int(buffer.frameLength)).first { abs(data[0][$0]) > threshold }
    }

    /// The host seconds of the first sample above `threshold` within `within` seconds of `time`.
    private static func firstOnset(
        in blocks: [(hostTime: UInt64, samples: [Float])],
        above threshold: Float,
        near time: Double,
        within: Double = 0.2,
        sampleRate: Double
    ) -> Double? {
        for block in blocks {
            let blockStart = AVAudioTime.seconds(forHostTime: block.hostTime)
            for (i, value) in block.samples.enumerated() where abs(value) > threshold {
                let onset = blockStart + Double(i) / sampleRate
                if abs(onset - time) < within { return onset }
            }
        }
        return nil
    }
}
