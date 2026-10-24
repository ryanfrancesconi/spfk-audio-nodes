// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// The transport's real-time start: the player started on a future host time while the node has
/// already been pulling at the rate. Runs on the output device, silenced after the node.
@Suite(.tags(.hardware, .engine), .serialized)
final class TimePitchHostTimeStartTests: TestCaseModel {
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var blocks: [(hostTime: UInt64, samples: [Float])] = []
    }

    @Test(arguments: [0.5, 2] as [Double])
    func hostTimeStartLandsAtTheRate(rate: Double) async throws {
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let timePitch = try await TimePitch()
        timePitch.rate = AUValue(rate)

        engine.attach(player)
        engine.attach(mixer)
        engine.attach(timePitch.avAudioNode)
        engine.connect(player, to: mixer, format: format)
        engine.connect(mixer, to: timePitch.avAudioNode, format: format)
        engine.connect(timePitch.avAudioNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        let capture = Capture()
        timePitch.avAudioNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, time in
            guard time.isHostTimeValid, let data = buffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            capture.lock.withLock { capture.blocks.append((time.hostTime, samples)) }
        }

        try engine.start()
        defer {
            timePitch.avAudioNode.removeTap(onBus: 0)
            engine.stop()
        }

        // The node pulls at the rate for a while before anything plays.
        try await Task.sleep(for: .milliseconds(500))

        let spacing = Int(sampleRate / 2)
        let passFrames = 3 * Int(sampleRate)
        let input = try TimePitchRig.makeClicks(frames: passFrames, every: spacing, first: spacing / 2)
        let rebuilt = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength))
        rebuilt.frameLength = input.frameLength
        for c in 0 ..< 2 { rebuilt.floatChannelData?[c].update(from: input.floatChannelData![c], count: Int(input.frameLength)) }

        let latency = timePitch.latency(atRate: rate)
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1)
        player.scheduleBuffer(rebuilt, at: AVAudioTime(sampleTime: 0, atRate: sampleRate), completionHandler: nil)
        player.play(at: AVAudioTime(hostTime: startHostTime))

        try await Task.sleep(for: .seconds(0.4 + latency + 3.2 / rate))

        let blocks = capture.lock.withLock { capture.blocks }
        var landings: [Double] = []
        for click in stride(from: spacing / 2, to: passFrames, by: spacing) {
            let expected = AVAudioTime.seconds(forHostTime: startHostTime) + latency + Double(click) / sampleRate / rate
            var bestTime = 0.0, bestValue: Float = 0
            for block in blocks {
                let blockStart = AVAudioTime.seconds(forHostTime: block.hostTime)
                for (i, value) in block.samples.enumerated() where abs(value) > bestValue {
                    let time = blockStart + Double(i) / sampleRate
                    if abs(time - expected) < 0.2 {
                        bestValue = abs(value)
                        bestTime = time
                    }
                }
            }
            if bestValue > 0.05 { landings.append((bestTime - expected) * 1000) }
        }

        reportTimePitch(
            "host time start \(rate)x at \(sampleRate) Hz",
            "\(landings.count) clicks, deviations ms \(landings.map { String(format: "%.2f", $0) })"
        )
        #expect(landings.count == 6)
        // The player converts the start's lead to input samples at the nominal rate.
        withKnownIssue("A host-time start through an engaged node lands off by about lead × (1 / rate − 1)") {
            #expect(landings.allSatisfy { abs($0) < 1 })
        }
    }
}
