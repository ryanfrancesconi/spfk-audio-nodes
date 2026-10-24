// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import Accelerate
import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// Player → mixer → TimePitch → output, rendered offline: the chain the transport builds, where
/// the node pulls `rate` × the frames it renders through a mixer fed by a player node.
final class TimePitchRig {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let mixer = AVAudioMixerNode()
    let timePitch: TimePitch
    let format: AVAudioFormat
    let blockSize: AVAudioFrameCount
    private let block: AVAudioPCMBuffer

    init(
        sampleRate: Double = TimePitchRig.sampleRate,
        blockSize: AVAudioFrameCount = 512,
        throughMixer: Bool = true,
        configure: (TimePitch) throws -> Void = { _ in }
    ) async throws {
        format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        self.blockSize = blockSize
        timePitch = try await TimePitch()
        try configure(timePitch)

        engine.attach(player)
        engine.attach(timePitch.avAudioNode)
        if throughMixer {
            engine.attach(mixer)
            engine.connect(player, to: mixer, format: format)
            engine.connect(mixer, to: timePitch.avAudioNode, format: format)
        } else {
            engine.connect(player, to: timePitch.avAudioNode, format: format)
        }
        engine.connect(timePitch.avAudioNode, to: engine.outputNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: blockSize)
        try engine.start()
        block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: blockSize))
    }

    deinit { engine.stop() }

    /// The next `frames` frames, per channel. `beforeBlock` runs before each block with the frames
    /// already rendered by this call.
    func render(frames: Int, beforeBlock: (_ rendered: Int) throws -> Void = { _ in }) throws -> [[Float]] {
        var result: [[Float]] = [[], []]
        while result[0].count < frames {
            try beforeBlock(result[0].count)
            let count = min(AVAudioFrameCount(frames - result[0].count), blockSize)
            let status = try engine.renderOffline(count, to: block)
            try #require(status == .success)
            let rendered = TimePitchRig.channels(block)
            result[0] += rendered[0]
            result[1] += rendered[1]
        }
        return result
    }

    /// The node's latency at `rate` in frames; 0 bypassed.
    func latencyFrames(atRate rate: Double) -> AVAudioFramePosition {
        timePitch.isBypassed ? 0 : AVAudioFramePosition((timePitch.latency(atRate: rate) * format.sampleRate).rounded())
    }

    /// Starts the player so that its frame 0 is heard at output `sampleTime`: the node is held until
    /// its latency before then, and the player started on the upstream time the hold returns.
    @discardableResult
    func startHeld(heardAt sampleTime: AVAudioFramePosition, rate: Double) throws -> AVAudioFramePosition {
        let upstream = try #require(timePitch.holdStart(untilSampleTime: sampleTime - latencyFrames(atRate: rate)))
        player.play(at: AVAudioTime(sampleTime: upstream, atRate: format.sampleRate))
        return upstream
    }

    /// Renders `frames` from a fresh play of `input`.
    func play(_ input: AVAudioPCMBuffer, frames: Int) throws -> [[Float]] {
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()
        return try render(frames: frames)
    }
}

// MARK: - Signals

extension TimePitchRig {
    static let sampleRate: Double = 48000

    static func channels(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let data = buffer.floatChannelData else { return [] }
        return (0 ..< Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
        }
    }

    static func makeBuffer(_ channels: [[Float]], sampleRate: Double = sampleRate) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        let data = try #require(buffer.floatChannelData)
        for (c, samples) in channels.enumerated() {
            data[c].update(from: samples, count: samples.count)
        }
        return buffer
    }

    /// Single-sample clicks of 1 at `first + k · every` on both channels.
    static func makeClicks(frames: Int, every: Int, first: Int) throws -> AVAudioPCMBuffer {
        var samples = [Float](repeating: 0, count: frames)
        for frame in stride(from: first, to: frames, by: every) {
            samples[frame] = 1
        }
        return try makeBuffer([samples, samples])
    }

    static func makeNoise(frames: Int) throws -> AVAudioPCMBuffer {
        var seed: UInt32 = 0xBEEF
        let channels = (0 ..< 2).map { _ in
            (0 ..< frames).map { _ -> Float in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.4
            }
        }
        return try makeBuffer(channels)
    }

    static func tabla() throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: TestBundleResources.shared.tabla_wav)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        while buffer.frameLength < AVAudioFrameCount(file.length) {
            let before = buffer.frameLength
            try file.read(into: buffer)
            if buffer.frameLength == before { break }
        }
        return buffer
    }
}

// MARK: - Measures

/// The frame of the largest magnitude within `radius` of `expected`.
func peakFrame(in samples: [Float], near expected: Int, radius: Int) -> Int {
    let lower = max(0, expected - radius)
    let upper = min(samples.count, expected + radius + 1)
    guard lower < upper else { return -1 }
    return (lower ..< upper).max { abs(samples[$0]) < abs(samples[$1]) } ?? -1
}

/// The lag of `measured` against `reference` with the highest normalized correlation, searched
/// over `lags`, and that correlation. Both are compared over `range` of the reference.
func bestAlignment(_ measured: [Float], _ reference: [Float], range: Range<Int>, lags: ClosedRange<Int>) -> (lag: Int, correlation: Double) {
    var best = (lag: 0, correlation: -2.0)
    var rr: Float = 0
    reference.withUnsafeBufferPointer { r in vDSP_svesq(r.baseAddress! + range.lowerBound, 1, &rr, vDSP_Length(range.count)) }
    for lag in lags where range.lowerBound + lag >= 0 && range.upperBound + lag <= measured.count {
        var dot: Float = 0, mm: Float = 0
        measured.withUnsafeBufferPointer { m in
            reference.withUnsafeBufferPointer { r in
                let mStart = m.baseAddress! + range.lowerBound + lag
                vDSP_dotpr(mStart, 1, r.baseAddress! + range.lowerBound, 1, &dot, vDSP_Length(range.count))
                vDSP_svesq(mStart, 1, &mm, vDSP_Length(range.count))
            }
        }
        let correlation = mm > 0 && rr > 0 ? Double(dot) / (Double(mm) * Double(rr)).squareRoot() : 0
        if correlation > best.correlation { best = (lag, correlation) }
    }
    return best
}

/// The correlation of two signals' RMS envelopes in 10 ms windows at 48 kHz, about their means: how
/// alike they are in level over time, whatever their phase.
func envelopeCorrelation(_ a: [Float], _ b: [Float]) -> Double {
    let window = 480
    func envelope(_ x: [Float]) -> [Double] {
        stride(from: 0, to: x.count - window, by: window).map { rmsDB(x[$0 ..< $0 + window]) }
    }
    let ea = envelope(a), eb = envelope(b)
    let ma = ea.reduce(0, +) / Double(ea.count), mb = eb.reduce(0, +) / Double(eb.count)
    var dot = 0.0, aa = 0.0, bb = 0.0
    for (x, y) in zip(ea, eb) {
        dot += (x - ma) * (y - mb); aa += (x - ma) * (x - ma); bb += (y - mb) * (y - mb)
    }
    return dot / (aa * bb).squareRoot()
}

func rmsDB(_ samples: ArraySlice<Float>) -> Double {
    let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))
    return 10 * log10(max(power, 1e-30))
}

/// The residual of `measured` (shifted by `lag`) against `reference`, in dB relative to the reference.
func residualDB(_ measured: [Float], _ reference: [Float], range: Range<Int>, lag: Int) -> Double {
    var error = 0.0, power = 0.0
    for i in range where i + lag >= 0 && i + lag < measured.count {
        let d = Double(measured[i + lag]) - Double(reference[i])
        error += d * d
        power += Double(reference[i]) * Double(reference[i])
    }
    return 10 * log10(max(error, 1e-30) / max(power, 1e-30))
}

/// One measured value, printed in a form the log can be grepped for.
func reportTimePitch(_ label: String, _ value: CustomStringConvertible) {
    print("TIMEPITCH-MEASURE \(label): \(value)")
}
