// Copyright Ryan Francesconi. All Rights Reserved.

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// Six channels, each holding a constant equal to its index plus one, so a rendered buffer says
/// which source channel landed in each slot.
private final class ChannelIndexSource: @unchecked Sendable, SeekablePCMSource {
    let processingFormat: AVAudioFormat
    let totalFrameCount: AVAudioFramePosition = 48000 * 2

    private(set) var framePosition: AVAudioFramePosition = 0

    init(layoutTag: AudioChannelLayoutTag) {
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            fatalError("a defined layout tag is always constructible")
        }

        processingFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
    }

    func seek(toFrame frame: AVAudioFramePosition) throws {
        framePosition = max(0, min(frame, totalFrameCount))
    }

    func readNextChunk(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws -> AVAudioFrameCount {
        let written = min(frameCount, AVAudioFrameCount(max(0, totalFrameCount - framePosition)))
        buffer.frameLength = written

        guard written > 0, let channels = buffer.floatChannelData else { return 0 }

        for channel in 0 ..< Int(processingFormat.channelCount) {
            channels[channel].update(repeating: Float(channel + 1) * 0.1, count: Int(written))
        }

        framePosition += AVAudioFramePosition(written)
        return written
    }
}

@Suite(.tags(.engine), .serialized)
final class StreamPlayerMultichannelTests: TestCaseModel {
    /// Renders one block of `frameCount` frames, returning the first sample of every channel.
    private func renderFirstSamples(
        source: ChannelIndexSource,
        throughMixer: Bool
    ) async throws -> [Float] {
        let engine = AVAudioEngine()
        let player = StreamPlayer()
        let format = source.processingFormat

        engine.attach(player.playerNode)

        if throughMixer {
            engine.connect(player.playerNode, to: engine.mainMixerNode, format: format)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        } else {
            engine.connect(player.playerNode, to: engine.outputNode, format: format)
        }

        try await player.load(source: source, url: URL(fileURLWithPath: "/tmp/six.mka"), duration: 2)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()

        try await player.schedule(from: 0, to: 2)
        try player.play()
        try await wait(for: player.playerNode.isPlaying, timeout: 5)
        try await wait(sec: 0.25)

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        let status = try engine.renderOffline(512, to: buffer)
        try #require(status == .success)

        let channels = try #require(buffer.floatChannelData)
        return (0 ..< Int(buffer.format.channelCount)).map { channels[$0][256] }
    }

    @Test func everyChannelArrivesInPlace() async throws {
        let source = ChannelIndexSource(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)
        let samples = try await renderFirstSamples(source: source, throughMixer: false)

        #expect(samples.count == 6)

        for (channel, sample) in samples.enumerated() {
            #expect(abs(sample - Float(channel + 1) * 0.1) < 1e-6, "channel \(channel): \(sample)")
        }
    }

    @Test func everyChannelArrivesInPlaceThroughTheMainMixer() async throws {
        let source = ChannelIndexSource(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)
        let samples = try await renderFirstSamples(source: source, throughMixer: true)

        #expect(samples.count == 6)

        for (channel, sample) in samples.enumerated() {
            #expect(abs(sample - Float(channel + 1) * 0.1) < 1e-6, "channel \(channel): \(sample)")
        }
    }
}
