// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import Testing

@testable import SPFKAudioNodes

/// Player → ChannelGain → output, rendered offline: what a gain or an automation curve actually
/// does to the signal, frame by frame.
enum GainRenderHarness {
    static let sampleRate: Double = 48000

    static func makeBuffer(frames: AVAudioFrameCount, fill: (_ channel: Int, _ frame: Int) -> Float) throws -> AVAudioPCMBuffer {
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

    static func makeDC(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try makeBuffer(frames: frames) { _, _ in 1 }
    }

    static func makeDC(seconds: TimeInterval) throws -> AVAudioPCMBuffer {
        try makeDC(frames: AVAudioFrameCount((seconds * sampleRate).rounded()))
    }

    static func channels(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let data = buffer.floatChannelData else { return [] }
        return (0 ..< Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
        }
    }

    /// The anchor that puts event time zero on the first rendered frame.
    static var renderStart: AVAudioTime { AVAudioTime(sampleTime: 0, atRate: sampleRate) }

    /// Renders `input` in blocks of `blockSize`. `configure` runs before the nodes are connected, and
    /// so before render resources are allocated, so its sets are not dezippered. `started` runs once
    /// the engine is running, before the first render. `beforeBlock` runs before each block with the
    /// number of frames already rendered.
    static func render(
        _ input: AVAudioPCMBuffer,
        blockSize: AVAudioFrameCount = 4096,
        configure: (ChannelGain) throws -> Void = { _ in },
        started: (ChannelGain) throws -> Void = { _ in },
        beforeBlock: (_ framesRendered: Int, ChannelGain) throws -> Void = { _, _ in }
    ) async throws -> [[Float]] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let channelGain = try await ChannelGain()
        try configure(channelGain)

        engine.attach(player)
        engine.attach(channelGain.avAudioNode)
        engine.connect(player, to: channelGain.avAudioNode, format: input.format)
        engine.connect(channelGain.avAudioNode, to: engine.outputNode, format: input.format)

        try engine.enableManualRenderingMode(.offline, format: input.format, maximumFrameCount: blockSize)
        try engine.start()
        defer { engine.stop() }

        player.scheduleBuffer(input, completionHandler: nil)
        player.play()
        try started(channelGain)

        let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: blockSize))
        var result: [[Float]] = [[], []]
        var remaining = input.frameLength

        while remaining > 0 {
            try beforeBlock(result[0].count, channelGain)
            let status = try engine.renderOffline(min(remaining, blockSize), to: block)
            try #require(status == .success)
            let rendered = channels(block)
            result[0] += rendered[0]
            result[1] += rendered[1]
            remaining -= block.frameLength
        }

        return result
    }
}

// MARK: - Measures

/// The largest absolute difference between two curves, where it occurs, and the dB error there.
struct CurveError: CustomStringConvertible {
    var maxAbs: Float = 0
    var frame: Int = -1
    var maxDB: Float = 0
    var dBFrame: Int = -1

    /// `floor` keeps the dB measure off frames where the reference is effectively silent.
    init(_ measured: ArraySlice<Float>, _ reference: ArraySlice<Float>, dBFloor: Float = 0.001) {
        for (m, r) in zip(zip(measured.indices, measured), reference) {
            let error = abs(m.1 - r)
            if error > maxAbs { maxAbs = error; frame = m.0 }

            guard r >= dBFloor else { continue }
            let db = abs(20 * log10(max(m.1, 1e-9) / r))
            if db > maxDB { maxDB = db; dBFrame = m.0 }
        }
    }

    init(_ measured: [Float], _ reference: [Float], dBFloor: Float = 0.001) {
        self.init(measured[...], reference[...], dBFloor: dBFloor)
    }

    var description: String {
        String(format: "max %.6f at frame %d, %.3f dB at frame %d", maxAbs, frame, maxDB, dBFrame)
    }
}

extension Array where Element == Float {
    /// The largest step between adjacent frames, and the frame it lands on.
    var largestStep: (step: Float, frame: Int) {
        var best: (Float, Int) = (0, -1)
        for i in indices.dropFirst() where abs(self[i] - self[i - 1]) > best.0 {
            best = (abs(self[i] - self[i - 1]), i)
        }
        return best
    }
}

/// One measured value, printed in a form the log can be grepped for.
func reportMeasure(_ label: String, _ value: CustomStringConvertible) {
    print("AUTOMATION-MEASURE \(label): \(value)")
}
