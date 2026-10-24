// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTempo
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// What a held start sounds like and when its last buffer reports itself played. Reports only.
@Suite(.tags(.engine), .serialized)
final class TimePitchHeldStartReports: TestCaseModel {
    private let sampleRate = TimePitchRig.sampleRate

    /// The first 200 ms after a held start at source frame s, which the kernel begins from silence,
    /// against `TimePitchRenderer`'s render of the same window given the real source before s. A
    /// window a second later is the baseline: the preview is not sample-equal to a render anywhere.
    @Test(arguments: [0.5, 0.75, 1.5, 2] as [Double])
    func onsetWithoutContext(rate: Double) async throws {
        let tabla = try TimePitchRig.tabla()
        let source = TimePitchRig.channels(tabla)
        let start = Int(sampleRate)
        let window = Int(sampleRate / 5)
        let baselineAt = Int(sampleRate)

        let rig = try await TimePitchRig { $0.rate = AUValue(rate) }
        _ = try rig.render(frames: 20 * 512)
        let now = rig.engine.manualRenderingSampleTime
        let heard = now + rig.latencyFrames(atRate: rate) + 1000
        rig.player.scheduleBuffer(try TimePitchRig.makeBuffer(source.map { Array($0[start...]) }), completionHandler: nil)
        try rig.startHeld(heardAt: heard, rate: rate)
        let live = try rig.render(frames: Int(heard - now) + baselineAt + window + 960)

        let materialFrames = Int((Double(baselineAt + window) * rate).rounded(.up)) + 1
        let reference = TimePitchRig.channels(try await TimePitchRenderer.render(
            tabla, material: start ..< start + materialFrames, description: TimePitchDescription(rate: rate), quality: .best
        ))

        for (label, offset) in [("onset", 0), ("baseline 1 s later", baselineAt)] {
            let at = Int(heard - now) + offset
            let measured = Array(live[0][(at - 480) ..< (at + window + 480)])
            let expected = Array(reference[0][offset ..< offset + window])
            let best = bestAlignment(measured, expected + [Float](repeating: 0, count: 960), range: 0 ..< window, lags: 0 ... 960)
            let aligned = Array(measured[best.lag ..< best.lag + window])
            let firstTwenty = Int(sampleRate / 50)
            reportTimePitch(
                "held start \(label) vs render \(rate)x",
                String(format: "lag %+d, correlation %.4f, 10 ms envelope correlation %.4f, level %+.2f dB, first 20 ms level %+.2f dB",
                       best.lag - 480, best.correlation, envelopeCorrelation(aligned, expected),
                       rmsDB(aligned[...]) - rmsDB(expected[...]),
                       rmsDB(aligned[..<firstTwenty]) - rmsDB(expected[..<firstTwenty]))
            )
        }
    }

    /// When each completion type fires for the last buffer through the node, against the output
    /// frame its last sample is pulled at and the frame it is heard at. Callbacks arrive
    /// asynchronously, so each block waits for them, and the frame reported is the end of the
    /// block rendered last.
    @Test(arguments: [(0.5, false), (1, false), (2, false), (1, true)] as [(Double, Bool)])
    func lastBufferCompletion(rate: Double, bypassed: Bool) async throws {
        for type in [AVAudioPlayerNodeCompletionCallbackType.dataConsumed, .dataRendered, .dataPlayedBack] {
            try await reportCompletion(type, rate: rate, bypassed: bypassed)
        }
    }

    private func reportCompletion(_ type: AVAudioPlayerNodeCompletionCallbackType, rate: Double, bypassed: Bool) async throws {
        final class Callback: @unchecked Sendable {
            let lock = NSLock()
            var renderedFrames: Int64 = 0
            var firedAt: Int64?
        }
        let rig = try await TimePitchRig {
            $0.rate = AUValue(rate)
            $0.isBypassed = bypassed
        }
        let heardRate = bypassed ? 1 : rate
        _ = try rig.render(frames: 20 * 512)
        let now = rig.engine.manualRenderingSampleTime

        let frames = Int(sampleRate / 2)
        var samples = [Float](repeating: 0, count: frames)
        samples[frames - 1] = 1
        let callback = Callback()
        rig.player.scheduleBuffer(try TimePitchRig.makeBuffer([samples, samples]), at: nil, completionCallbackType: type) { _ in
            callback.lock.withLock { callback.firedAt = callback.firedAt ?? callback.renderedFrames }
        }
        let latency = rig.latencyFrames(atRate: rate)
        let heard = now + latency + 1000
        try rig.startHeld(heardAt: heard, rate: rate)

        let lastPulled = heard - latency + Int64((Double(frames - 1) / heardRate).rounded())
        let lastHeard = heard + Int64((Double(frames - 1) / heardRate).rounded())
        var output: [Float] = []
        while Int64(output.count) < lastHeard - now + 2 * Int64(sampleRate) {
            output += try rig.render(frames: 512)[0]
            callback.lock.withLock { callback.renderedFrames = rig.engine.manualRenderingSampleTime }
            try await Task.sleep(for: .milliseconds(2))
        }

        let foundHeard = now + Int64(peakFrame(in: output, near: Int(lastHeard - now), radius: 1200))
        let label = "\(type == .dataConsumed ? "consumed" : type == .dataRendered ? "rendered" : "playedBack") \(rate)x bypassed \(bypassed)"
        guard let fired = callback.lock.withLock({ callback.firedAt }) else {
            reportTimePitch(label, "never fired within 2 s after the last sample was heard")
            return
        }
        reportTimePitch(
            label,
            "fired by output frame \(fired - now); last sample pulled at \(lastPulled - now), heard at \(foundHeard - now) (predicted \(lastHeard - now)); fired − pulled \(fired - lastPulled), fired − heard \(fired - foundHeard)"
        )
    }
}
