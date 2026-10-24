// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// What the ChannelGain renders: gain, bypass and channel operations, sample for sample.
@Suite(.tags(.engine), .serialized)
final class ChannelGainRenderTests: TestCaseModel {
    private let sampleRate = GainRenderHarness.sampleRate

    private func makeDC(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try GainRenderHarness.makeDC(frames: frames)
    }

    private func makeNoise(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        var seed: UInt32 = 0xBEEF
        return try GainRenderHarness.makeBuffer(frames: frames) { _, _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.4
        }
    }

    private func channels(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        GainRenderHarness.channels(buffer)
    }

    func render(
        _ input: AVAudioPCMBuffer,
        blockSize: AVAudioFrameCount = 4096,
        configure: (ChannelGain) throws -> Void = { _ in },
        started: (ChannelGain) throws -> Void = { _ in }
    ) async throws -> [[Float]] {
        try await GainRenderHarness.render(input, blockSize: blockSize, configure: configure, started: started)
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

    @Test func setWhileRunningReachesTheDSP() async throws {
        var readBack: AUValue?

        let output = try await render(makeDC(frames: 4096), started: { channelGain in
            channelGain.leftGain = 0.25
            if let dsp = (channelGain.avAudioNode.auAudioUnit as? SPFKAudioUnit)?.dsp {
                readBack = getParameterValueDSP(dsp, ChannelGainParameter.leftGain.rawValue)
            }
        })

        #expect(readBack == 0.25)
        // Dezippered over 20 ms: 960 frames at 48 kHz.
        #expect(output[0][1024...].allSatisfy { $0 == 0.25 })
        #expect(output[1].allSatisfy { $0 == 1 })
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

    @Test func channelOperationChangedWhileRunningRendersWhole() async throws {
        let input = try makeNoise(frames: 4096)

        let output = try await render(
            input,
            configure: { $0.channelOperation = .midSideDecode(width: 0.37) },
            started: { $0.channelOperation = .mono(.left) }
        )

        let written = try channels(input.applyingChannelOperation(.mono(.left)))
        #expect(output[0] == written[0])
        #expect(output[1] == written[0])
    }

    // MARK: - Upstream failure

    /// The upstream's own status reaches the engine.
    @Test func upstreamFailureFailsTheRender() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(format: format) { _, _, _, _ in kAudioUnitErr_NoConnection }
        let channelGain = try await ChannelGain()

        engine.attach(source)
        engine.attach(channelGain.avAudioNode)
        engine.connect(source, to: channelGain.avAudioNode, format: format)
        engine.connect(channelGain.avAudioNode, to: engine.outputNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()
        defer { engine.stop() }

        let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        let error = #expect(throws: NSError.self) { try engine.renderOffline(512, to: block) }
        #expect(error?.code == Int(kAudioUnitErr_NoConnection))
    }

    // MARK: - Automation timing

    private func automate(_ events: [AutomationEvent]) -> (ChannelGain) throws -> Void {
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

    @Test(.tags(.automation), arguments: [512, 4096] as [AVAudioFrameCount])
    func automatedStepLandsOnItsFrame(blockSize: AVAudioFrameCount) async throws {
        let output = try await render(
            makeDC(frames: 48000),
            blockSize: blockSize,
            started: automate([AutomationEvent(targetValue: 0, startTime: 0.5, rampDuration: 0)])
        )
        expectFirstFrame(in: output, where: { $0 < 0.99999 }, at: 24000)
    }

    @Test(.tags(.automation), arguments: [512, 4096] as [AVAudioFrameCount])
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
