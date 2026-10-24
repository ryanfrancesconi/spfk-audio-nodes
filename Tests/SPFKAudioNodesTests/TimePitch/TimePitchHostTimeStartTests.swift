// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// The transport's real-time start: the node held until its latency before a future host time H,
/// and the player started at the release, after the node has been pulling at the rate. Source p
/// must be heard at H + p / r. Runs on the output device, silenced after the node.
@Suite(.tags(.hardware, .engine), .serialized)
final class TimePitchHostTimeStartTests: TestCaseModel {
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var blocks: [(hostTime: UInt64, samples: [Float])] = []
        var playedBackHostTime: UInt64?
    }

    /// The control: the node bypassed and the player started on its own host time, which the
    /// transport relies on landing to the frame. Whatever this reports is the measurement's own offset.
    @Test func bypassedControl() async throws {
        try await measure(rate: 1, held: false, bypassed: true)
    }

    @Test(arguments: [(0.5, false), (1, false), (2, false), (1, true)] as [(Double, Bool)])
    func heldStartLandsAtItsTime(rate: Double, bypassed: Bool) async throws {
        try await measure(rate: rate, held: true, bypassed: bypassed)
    }

    private func measure(rate: Double, held: Bool, bypassed: Bool) async throws {
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let timePitch = try await TimePitch()
        timePitch.rate = AUValue(rate)
        timePitch.isBypassed = bypassed

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

        let latency = bypassed ? 0 : timePitch.latency(atRate: rate)
        let heardRate = bypassed ? 1 : rate
        let heardHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1 + latency)
        let releaseHostTime = heardHostTime - AVAudioTime.hostTime(forSeconds: latency)
        player.scheduleBuffer(rebuilt, at: AVAudioTime(sampleTime: 0, atRate: sampleRate), completionCallbackType: .dataPlayedBack) { _ in
            let now = mach_absolute_time()
            capture.lock.withLock { capture.playedBackHostTime = now }
        }
        if held { timePitch.holdStart(untilHostTime: releaseHostTime) }
        player.play(at: AVAudioTime(hostTime: releaseHostTime))

        try await Task.sleep(for: .seconds(0.9 + latency + 3.2 / heardRate))

        let blocks = capture.lock.withLock { capture.blocks }
        var landings: [Double] = []
        for click in stride(from: spacing / 2, to: passFrames, by: spacing) {
            let expected = AVAudioTime.seconds(forHostTime: heardHostTime) + Double(click) / sampleRate / heardRate
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
            "host time start \(rate)x, held \(held), bypassed \(bypassed), at \(sampleRate) Hz",
            "\(landings.count) clicks, deviations ms \(landings.map { String(format: "%.3f", $0) })"
        )
        // When the transport's completion fires, against when the pass's last frame is heard. A report.
        let lastHeard = AVAudioTime.seconds(forHostTime: heardHostTime) + Double(passFrames - 1) / sampleRate / heardRate
        let playedBack = capture.lock.withLock { capture.playedBackHostTime }
        reportTimePitch(
            "dataPlayedBack \(rate)x, held \(held), bypassed \(bypassed)",
            playedBack.map { String(format: "fired %.1f ms after the last frame was heard", (AVAudioTime.seconds(forHostTime: $0) - lastHeard) * 1000) } ?? "never fired"
        )

        #expect(landings.count == 6)
        #expect(abs(landings.first ?? .infinity) < 0.1)
        // Tap host times drift from the device clock by about 15 ppm, in the control too.
        #expect(landings.allSatisfy { abs($0) < 0.2 })
    }
}
