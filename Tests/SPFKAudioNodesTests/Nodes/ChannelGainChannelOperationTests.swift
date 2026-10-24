// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// The ChannelGain's real-time channel stage must play exactly what the render's buffer step writes.
@Suite(.tags(.engine), .serialized)
final class ChannelGainChannelOperationTests: TestCaseModel {
    private let frameCount: AVAudioFrameCount = 4096

    private func makeInput() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let data = try #require(buffer.floatChannelData)
        var seed: UInt32 = 0xBEEF
        for ch in 0 ..< 2 {
            for i in 0 ..< Int(frameCount) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                data[ch][i] = Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.4
            }
        }
        return buffer
    }

    private func channels(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let data = buffer.floatChannelData else { return [] }
        return (0 ..< Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
        }
    }

    /// Player → ChannelGain → output, rendered offline. Connected straight to the output node so no mixer
    /// pan law touches the result.
    private func render(_ input: AVAudioPCMBuffer, operation: ChannelOperation) async throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let channelGain = try await ChannelGain()
        channelGain.channelOperation = operation

        engine.attach(player)
        engine.attach(channelGain.avAudioNode)
        engine.connect(player, to: channelGain.avAudioNode, format: input.format)
        engine.connect(channelGain.avAudioNode, to: engine.outputNode, format: input.format)

        try engine.enableManualRenderingMode(.offline, format: input.format, maximumFrameCount: frameCount)
        try engine.start()
        defer { engine.stop() }

        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        let output = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frameCount))
        let status = try engine.renderOffline(frameCount, to: output)
        #expect(status == .success)
        return output
    }

    @Test(arguments: [
        ChannelOperation.none, .swap, .mono(.average), .mono(.left), .mono(.right),
        .midSideDecode(width: 1), .midSideDecode(width: 0.37), .midSideDecode(width: 2), .midSideEncode,
    ])
    func channelGainMatchesBufferStep(operation: ChannelOperation) async throws {
        let input = try makeInput()
        let played = try await channels(render(input, operation: operation))
        let written = try channels(input.applyingChannelOperation(operation))

        if written.count == 1 {
            #expect(played[0] == written[0])
            #expect(played[1] == written[0])
        } else {
            #expect(played == written)
        }
    }

    @Test func channelOperationRoundTrips() async throws {
        let channelGain = try await ChannelGain()
        for operation in [ChannelOperation.swap, .mono(.right), .midSideDecode(width: 1.25), .midSideEncode, .none] {
            channelGain.channelOperation = operation
            #expect(channelGain.channelOperation == operation)
        }
    }
}
