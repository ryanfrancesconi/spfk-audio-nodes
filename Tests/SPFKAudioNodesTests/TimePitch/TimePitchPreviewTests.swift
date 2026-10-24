// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTempo
import SPFKTesting
import SPFKTimePitchKernel
import Testing

@testable import SPFKAudioNodes

/// What the preview plays against what a render writes, from the same kernel.
@Suite(.tags(.engine), .serialized)
final class TimePitchPreviewTests: TestCaseModel {
    private let sampleRate = TimePitchRig.sampleRate

    private struct Comparison: CustomStringConvertible {
        var lagOffset: Int
        var correlation: Double
        var residualDB: Double
        var levelDifferenceDB: Double
        var envelopeCorrelation: Double

        var description: String {
            String(format: "lag offset %d, correlation %.5f, residual %.2f dB, level difference %+.3f dB, 10 ms envelope correlation %.5f",
                   lagOffset, correlation, residualDB, levelDifferenceDB, envelopeCorrelation)
        }
    }

    /// `measured` against `reference`, aligned within `search` of `expectedLag`. The first and
    /// last half second are left out: a live kernel has no context before its start.
    private func compare(_ measured: [Float], _ reference: [Float], expectedLag: Int, search: Int = 480) -> Comparison {
        let range = Int(sampleRate / 2) ..< (reference.count - Int(sampleRate / 2))
        let best = bestAlignment(measured, reference, range: range, lags: (expectedLag - search) ... (expectedLag + search))
        let aligned = measured[(range.lowerBound + best.lag) ..< (range.upperBound + best.lag)]
        return Comparison(
            lagOffset: best.lag - expectedLag,
            correlation: best.correlation,
            residualDB: residualDB(measured, reference, range: range, lag: best.lag),
            levelDifferenceDB: rmsDB(aligned) - rmsDB(reference[range]),
            envelopeCorrelation: Self.envelopeCorrelation(Array(aligned), Array(reference[range]))
        )
    }

    /// The correlation of two signals' RMS envelopes in 10 ms windows, about their means: how alike
    /// they are in level over time, whatever their phase.
    private static func envelopeCorrelation(_ a: [Float], _ b: [Float]) -> Double {
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

    /// The node's output for `input`, with the frames of latency it starts with.
    private func preview(_ input: AVAudioPCMBuffer, rate: Double) async throws -> (output: [[Float]], latencyFrames: Int) {
        let rig = try await TimePitchRig { $0.rate = AUValue(rate) }
        let latencyFrames = Int((rig.timePitch.latency(atRate: rate) * sampleRate).rounded())
        let frames = TimePitchDescription(rate: rate).outputFrameCount(forInput: Int(input.frameLength))
        return (try rig.play(input, frames: frames + latencyFrames + 4800), latencyFrames)
    }

    /// The node against `TimePitchRenderer` at a constant rate.
    @Test(arguments: [0.75, 1.5] as [Double])
    func previewAgainstRender(rate: Double) async throws {
        let input = try TimePitchRig.tabla()
        let reference = try await TimePitchRig.channels(
            TimePitchRenderer.render(input, description: TimePitchDescription(rate: rate), quality: .best)
        )
        let live = try await preview(input, rate: rate)

        for channel in 0 ..< 2 {
            let comparison = compare(live.output[channel], reference[channel], expectedLag: live.latencyFrames)
            reportTimePitch("preview vs render \(rate)x ch\(channel)", comparison)
            #expect(abs(comparison.levelDifferenceDB) < 0.1)
        }
    }

    /// Which part of the preview-to-render difference `splitComputation` causes: the live kernel
    /// with it off and on, fed 512-frame blocks from the start, against the offline render.
    @Test func splitComputationAgainstRender() async throws {
        let rate = 0.75
        let input = try TimePitchRig.tabla()
        let reference = try await TimePitchRig.channels(
            TimePitchRenderer.render(input, description: TimePitchDescription(rate: rate), quality: .best)
        )
        let source = TimePitchRig.channels(input)

        for split in [false, true] {
            let kernel = try #require(TimePitchKernelCreate(2, sampleRate, 512, TimePitchKernelQualityBest, split))
            defer { TimePitchKernelDestroy(kernel) }
            TimePitchKernelSetTargets(kernel, rate, 1)
            TimePitchKernelReset(kernel)

            let latencyFrames = Int((TimePitchKernelLatencySeconds(kernel, rate) * sampleRate).rounded())
            let total = reference[0].count + latencyFrames + 4800
            var left = [Float](repeating: 0, count: total)
            var right = [Float](repeating: 0, count: total)
            var read = 0

            for start in stride(from: 0, to: total, by: 512) {
                let frames = UInt32(min(512, total - start))
                let needed = Int(TimePitchKernelInputFramesNeeded(kernel, frames))
                let block = (0 ..< 2).map { c in (0 ..< needed).map { read + $0 < source[c].count ? source[c][read + $0] : 0 } }
                read += needed
                block[0].withUnsafeBufferPointer { inLeft in
                    block[1].withUnsafeBufferPointer { inRight in
                        left.withUnsafeMutableBufferPointer { outLeft in
                            right.withUnsafeMutableBufferPointer { outRight in
                                let inputs: [UnsafePointer<Float>?] = [inLeft.baseAddress, inRight.baseAddress]
                                let outputs: [UnsafeMutablePointer<Float>?] = [outLeft.baseAddress! + start, outRight.baseAddress! + start]
                                _ = TimePitchKernelProcess(kernel, inputs, UInt32(needed), outputs, frames)
                            }
                        }
                    }
                }
            }

            let comparison = compare(left, reference[0], expectedLag: latencyFrames)
            reportTimePitch("live kernel split \(split) vs render \(rate)x", comparison)
            #expect(abs(comparison.levelDifferenceDB) < 0.1)
        }
    }

    /// Decision 25: the preview stretches and then applies the channel edit (the ChannelGain sits
    /// after the node), where the render applies it first. Both orders run through the node here,
    /// so the comparison holds only the order.
    @Test(arguments: [ChannelOperation.mono(.average), .midSideDecode(width: 1)])
    func channelEditOrder(operation: ChannelOperation) async throws {
        let rate = 0.75
        let input = try TimePitchRig.tabla()

        // The render's order. A mono result plays on both sides, as the ChannelGain plays it.
        var channeled = TimePitchRig.channels(try input.applyingChannelOperation(operation))
        if channeled.count == 1 { channeled.append(channeled[0]) }
        let channelFirst = try await preview(TimePitchRig.makeBuffer(channeled), rate: rate)

        // The preview's order.
        let stretched = try await preview(input, rate: rate)
        let stretchFirst = TimePitchRig.channels(try TimePitchRig.makeBuffer(stretched.output).applyingChannelOperation(operation))

        for channel in stretchFirst.indices {
            let comparison = compare(stretchFirst[channel], channelFirst.output[channel], expectedLag: 0, search: 0)
            reportTimePitch("channel order \(operation) ch\(channel) at \(rate)x", comparison)
        }
    }
}
