// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// What the Fader renders: gain, bypass and channel operations, sample for sample.
@Suite(.tags(.engine), .serialized)
final class FaderRenderTests: TestCaseModel {
    private let sampleRate: Double = 48000

    private func makeBuffer(frames: AVAudioFrameCount, fill: (_ channel: Int, _ frame: Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for ch in 0 ..< 2 {
            for i in 0 ..< Int(frames) {
                data[ch][i] = fill(ch, i)
            }
        }
        return buffer
    }

    private func makeDC(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try makeBuffer(frames: frames) { _, _ in 1 }
    }

    private func makeNoise(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        var seed: UInt32 = 0xBEEF
        return try makeBuffer(frames: frames) { _, _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.4
        }
    }

    private func channels(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let data = buffer.floatChannelData else { return [] }
        return (0 ..< Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
        }
    }

    /// Player → Fader → output, rendered offline in blocks of `blockSize`. `configure` runs before
    /// the nodes are connected, and so before render resources are allocated, so its sets are not
    /// dezippered. `started` runs once the engine is running, before the first render.
    func render(
        _ input: AVAudioPCMBuffer,
        blockSize: AVAudioFrameCount = 4096,
        configure: (Fader) throws -> Void = { _ in },
        started: (Fader) throws -> Void = { _ in }
    ) async throws -> [[Float]] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let fader = try await Fader()
        try configure(fader)

        engine.attach(player)
        engine.attach(fader.avAudioNode)
        engine.connect(player, to: fader.avAudioNode, format: input.format)
        engine.connect(fader.avAudioNode, to: engine.outputNode, format: input.format)

        try engine.enableManualRenderingMode(.offline, format: input.format, maximumFrameCount: blockSize)
        try engine.start()
        defer { engine.stop() }

        player.scheduleBuffer(input, completionHandler: nil)
        player.play()
        try started(fader)

        let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: blockSize))
        var result: [[Float]] = [[], []]
        var remaining = input.frameLength

        while remaining > 0 {
            let status = try engine.renderOffline(min(remaining, blockSize), to: block)
            try #require(status == .success)
            let rendered = channels(block)
            result[0] += rendered[0]
            result[1] += rendered[1]
            remaining -= block.frameLength
        }

        return result
    }

    // MARK: - Gain and bypass

    @Test func gainScalesDC() async throws {
        let output = try await render(makeDC(frames: 4096), configure: { $0.gain = 0.5 })
        #expect(output[0].allSatisfy { $0 == 0.5 })
        #expect(output[1].allSatisfy { $0 == 0.5 })
    }

    @Test func bypassPassesInputUnchanged() async throws {
        let input = try makeNoise(frames: 4096)
        let output = try await render(input, configure: {
            $0.gain = 0.3
            $0.channelOperation = .swap
            $0.isBypassed = true
        })
        #expect(output == channels(input))
    }

    /// Pins the render to the channel buffer step times each side's gain.
    @Test(arguments: [
        ChannelOperation.none, .swap, .mono(.average), .mono(.left), .mono(.right),
        .midSideDecode(width: 1), .midSideDecode(width: 0.37), .midSideEncode,
    ])
    func gainAndChannelOperationSnapshot(operation: ChannelOperation) async throws {
        let leftGain: Float = 0.7
        let rightGain: Float = 1.3
        let input = try makeNoise(frames: 4096)

        let output = try await render(input, configure: {
            $0.leftGain = leftGain
            $0.rightGain = rightGain
            $0.channelOperation = operation
        })

        var written = try channels(input.applyingChannelOperation(operation))
        if written.count == 1 { written.append(written[0]) }

        #expect(output[0] == written[0].map { $0 * leftGain })
        #expect(output[1] == written[1].map { $0 * rightGain })
    }

    // MARK: - Automation timing

    private func automate(_ events: [AutomationEvent]) -> (Fader) throws -> Void {
        { [sampleRate] in try $0.automate(events: events, startTime: AVAudioTime(sampleTime: 0, atRate: sampleRate)) }
    }

    /// Asserts both channels first satisfy `predicate` within two frames of `expected`.
    private func expectFirstFrame(
        in output: [[Float]], where predicate: (Float) -> Bool, at expected: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for channel in output {
            let frame = channel.firstIndex(where: predicate) ?? -1
            #expect(abs(frame - expected) <= 2, "first frame \(frame), expected \(expected)", sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: [512, 4096] as [AVAudioFrameCount])
    func automatedStepLandsOnItsFrame(blockSize: AVAudioFrameCount) async throws {
        let output = try await render(
            makeDC(frames: 48000),
            blockSize: blockSize,
            started: automate([AutomationEvent(targetValue: 0, startTime: 0.5, rampDuration: 0)])
        )
        expectFirstFrame(in: output, where: { $0 < 0.99999 }, at: 24000)
    }

    @Test(arguments: [512, 4096] as [AVAudioFrameCount])
    func automatedRampStartsAndEndsOnItsFrames(blockSize: AVAudioFrameCount) async throws {
        let output = try await render(
            makeDC(frames: 48000),
            blockSize: blockSize,
            started: automate([AutomationEvent(targetValue: 0, startTime: 0.25, rampDuration: 0.25)])
        )
        expectFirstFrame(in: output, where: { $0 < 0.99999 }, at: 12000)
        expectFirstFrame(in: output, where: { $0 == 0 }, at: 24000)
    }
}
