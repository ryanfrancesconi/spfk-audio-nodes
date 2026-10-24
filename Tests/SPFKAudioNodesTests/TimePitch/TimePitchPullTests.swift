// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKAudioNodesC
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// The architecture gate: a node that pulls `rate` × its output through a mixer fed by a player,
/// with the player started and looped as the transport does.
@Suite(.tags(.engine), .serialized)
final class TimePitchPullTests: TestCaseModel {
    private let sampleRate = TimePitchRig.sampleRate
    private let clickSpacing = 4800

    /// Where each click of `input` lands, against where `expected` puts it.
    private struct ClickLanding {
        var deviations: [Int] = []
        var weakest: Float = .infinity

        var worst: Int { deviations.map(abs).max() ?? .max }
        var description: String {
            "\(deviations.count) clicks, first \(deviations.first ?? 0), last \(deviations.last ?? 0), worst \(worst), weakest \(weakest)"
        }
    }

    private func landings(in output: [Float], clicks: [Int], expected: (Int) -> Double) -> ClickLanding {
        var landing = ClickLanding()
        for click in clicks {
            let predicted = expected(click)
            guard predicted + 1200 < Double(output.count) else { continue }
            let frame = peakFrame(in: output, near: Int(predicted.rounded()), radius: 1200)
            landing.deviations.append(frame - Int(predicted.rounded()))
            landing.weakest = min(landing.weakest, abs(output[frame]))
        }
        return landing
    }

    private func firstClick(in output: [Float]) -> Int? {
        output.indices.first { abs(output[$0]) > 0.2 }.map { peakFrame(in: output, near: $0, radius: 240) }
    }

    // MARK: - Pull counts

    /// Over a long run the node pulls exactly `rate` × what it renders, in sub-pulls at 2×, and
    /// every click comes out where the rate puts it, so nothing was dropped or pulled twice.
    @Test(arguments: [0.5, 2] as [Double])
    func pullsRateTimesItsOutput(rate: Double) async throws {
        let sourceFrames = 10 * Int(sampleRate)
        let input = try TimePitchRig.makeClicks(frames: sourceFrames, every: clickSpacing, first: clickSpacing / 2)
        let rig = try await TimePitchRig(blockSize: 512) { $0.rate = AUValue(rate) }

        let outputFrames = 400 * 512
        let output = try rig.play(input, frames: outputFrames)
        #expect(rig.timePitch.inputFramesPulled == Int64(Double(outputFrames) * rate))

        let latency = rig.timePitch.latency(atRate: rate) * sampleRate
        let clicks = Array(stride(from: clickSpacing / 2, to: sourceFrames, by: clickSpacing))
        let landing = landings(in: output[0], clicks: clicks) { Double($0) / rate + latency }

        reportTimePitch("pull \(rate)x", landing.description)
        #expect(landing.deviations.count > 10)
        #expect(landing.worst <= 2)
        #expect(landing.weakest > 0.05)
    }

    // MARK: - Held starts

    /// The transport's start: the node holds until its latency before H, and the player starts on
    /// the upstream time the hold returns. Source p is heard at H + p / r, and a pass queued behind
    /// the first at H + (D + p) / r.
    @Test(arguments: [(0.5, false), (1, false), (2, false), (1, true), (0.5, true)] as [(Double, Bool)])
    func heldStartAndLoopLandAtTheirTime(rate: Double, bypassed: Bool) async throws {
        let passFrames = Int(sampleRate)
        let input = try TimePitchRig.makeClicks(frames: passFrames, every: clickSpacing, first: clickSpacing / 2)
        let rig = try await TimePitchRig {
            $0.rate = AUValue(rate)
            $0.isBypassed = bypassed
        }
        let heardRate = bypassed ? 1 : rate

        // The node runs, pulling at the rate, before anything plays.
        _ = try rig.render(frames: 20 * 512)
        let renderStart = Int(rig.engine.manualRenderingSampleTime)
        let heard = rig.latencyFrames(atRate: rate) + 1000 // the release mid-block

        rig.player.scheduleBuffer(input, at: AVAudioTime(sampleTime: 0, atRate: sampleRate), completionHandler: nil)
        rig.player.scheduleBuffer(input, at: nil, completionHandler: nil)
        try rig.startHeld(heardAt: AVAudioFramePosition(renderStart) + heard, rate: rate)

        let output = try rig.render(frames: Int(heard) + Int(Double(2 * passFrames) / heardRate) + 2400)

        let firstPass = Array(stride(from: clickSpacing / 2, to: passFrames, by: clickSpacing))
        let bothPasses = firstPass + firstPass.map { $0 + passFrames }
        let landing = landings(in: output[0], clicks: bothPasses) { Double(heard) + Double($0) / heardRate }

        reportTimePitch("held start \(rate)x bypassed \(bypassed)", "\(landing.description), first click \(firstClick(in: output[0]) ?? -1)")
        #expect(landing.deviations.count == bothPasses.count)
        #expect(landing.worst <= 2)
    }

    // MARK: - Retime

    /// A rate change while playing. Reports where the change becomes audible, as the intercept
    /// of the clicks pulled after it, against the two candidate models.
    @Test func midPlayRateChangeIsHeardAfterTheLatency() async throws {
        let sourceFrames = 6 * Int(sampleRate)
        let input = try TimePitchRig.makeClicks(frames: sourceFrames, every: clickSpacing, first: clickSpacing / 2)
        let rig = try await TimePitchRig(blockSize: 480)

        let change = Int(sampleRate) // a block boundary at 480
        let inLatency = Double(rig.timePitch.latency(atRate: 1) - rig.timePitch.latency(atRate: 2)) * 2 * sampleRate
        let latencyBefore = rig.timePitch.latency(atRate: 1) * sampleRate

        rig.player.scheduleBuffer(input, completionHandler: nil)
        rig.player.play()
        let output = try rig.render(frames: change + 4 * Int(sampleRate)) { rendered in
            if rendered == change { rig.timePitch.rate = 0.5 }
        }

        let clicks = Array(stride(from: clickSpacing / 2, to: sourceFrames, by: clickSpacing))

        // Clicks the kernel had already taken in play at the old rate.
        let early = clicks.filter { Double($0) + inLatency < Double(change) - 2400 }
        let earlyLanding = landings(in: output[0], clicks: early) { Double($0) + latencyBefore }
        reportTimePitch("retime early clicks", earlyLanding.description)
        #expect(earlyLanding.worst <= 2)

        // Clicks pulled well after the change: t = change + c + 2 (p - change). Report c.
        let late = clicks.filter { $0 > change + Int(sampleRate) / 2 }
        var intercepts: [Double] = []
        for click in late {
            let guess = Double(change) + latencyBefore + 2 * Double(click - change)
            guard guess + 4800 < Double(output[0].count) else { continue }
            let frame = peakFrame(in: output[0], near: Int(guess), radius: 4800)
            intercepts.append(Double(frame - change) - 2 * Double(click - change))
        }
        let intercept = intercepts.reduce(0, +) / Double(max(intercepts.count, 1))
        let spread = (intercepts.max() ?? 0) - (intercepts.min() ?? 0)
        let outLatency = latencyBefore - inLatency
        let planModel = latencyBefore
        let newRateModel = outLatency + inLatency / 0.5

        reportTimePitch(
            "retime 1x->0.5x at frame \(change)",
            "intercept \(intercept) frames (spread \(spread) over \(intercepts.count) clicks); "
                + "plan model h + L(old) = \(planModel); h + outLat + inLat / new = \(newRateModel)"
        )
        #expect(intercepts.count > 10)
        #expect(spread <= 4)
    }
}
