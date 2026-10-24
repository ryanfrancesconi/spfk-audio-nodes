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

    // MARK: - Starts as the transport makes them

    /// The transport schedules the run at player sample 0 and starts the player at the engine's
    /// sample time (offline) after the node has already been running. Source s must be heard at
    /// P + L + s / rate, and a pass queued behind it at P + L + (D + s) / rate.
    @Test(arguments: [0.5, 2] as [Double])
    func transportStartAndLoopLandAtTheRate(rate: Double) async throws {
        let passFrames = Int(sampleRate)
        let input = try TimePitchRig.makeClicks(frames: passFrames, every: clickSpacing, first: clickSpacing / 2)
        let rig = try await TimePitchRig { $0.rate = AUValue(rate) }

        // The node runs, pulling at the rate, before anything plays.
        _ = try rig.render(frames: 20 * 512)
        let start = rig.engine.manualRenderingSampleTime

        rig.player.scheduleBuffer(input, at: AVAudioTime(sampleTime: 0, atRate: sampleRate), completionHandler: nil)
        rig.player.scheduleBuffer(input, at: nil, completionHandler: nil)
        rig.player.play(at: AVAudioTime(sampleTime: start, atRate: sampleRate))

        let latency = rig.timePitch.latency(atRate: rate) * sampleRate
        let output = try rig.render(frames: Int(Double(2 * passFrames) / rate + latency) + 2400)

        let firstPass = Array(stride(from: clickSpacing / 2, to: passFrames, by: clickSpacing))
        let bothPasses = firstPass + firstPass.map { $0 + passFrames }
        let landing = landings(in: output[0], clicks: bothPasses) { Double($0) / rate + latency }

        reportTimePitch("transport start \(rate)x", "start sample \(start), \(landing.description)")
        reportTimePitch("transport start \(rate)x first click", "found \(firstClick(in: output[0]) ?? -1), predicted \(Double(clickSpacing / 2) / rate + latency)")
        // The player keeps time by the node's input-sample counter, which runs at the rate, so a
        // sample-time start lands off by however far the counters have diverged.
        withKnownIssue("A sample-time start through an engaged node lands off its time") {
            #expect(landing.deviations.count == bothPasses.count)
            #expect(landing.worst <= 2)
        }
    }

    /// The node owns the start: it holds until an output sample, and the player is started at the
    /// upstream sample time the node's first pull will carry.
    @Test(arguments: [0.5, 2] as [Double])
    func heldStartAndLoopLandAtTheRate(rate: Double) async throws {
        let passFrames = Int(sampleRate)
        let input = try TimePitchRig.makeClicks(frames: passFrames, every: clickSpacing, first: clickSpacing / 2)
        let rig = try await TimePitchRig { $0.rate = AUValue(rate) }

        _ = try rig.render(frames: 20 * 512)
        let renderStart = rig.engine.manualRenderingSampleTime
        let start = renderStart + 1000 // mid-block

        let upstream = try #require(rig.timePitch.holdUntil(sampleTime: start))
        rig.player.scheduleBuffer(input, at: AVAudioTime(sampleTime: 0, atRate: sampleRate), completionHandler: nil)
        rig.player.scheduleBuffer(input, at: nil, completionHandler: nil)
        rig.player.play(at: AVAudioTime(sampleTime: upstream, atRate: sampleRate))

        let latency = rig.timePitch.latency(atRate: rate) * sampleRate
        let output = try rig.render(frames: Int(Double(2 * passFrames) / rate + latency) + 4000)

        let firstPass = Array(stride(from: clickSpacing / 2, to: passFrames, by: clickSpacing))
        let bothPasses = firstPass + firstPass.map { $0 + passFrames }
        let landing = landings(in: output[0], clicks: bothPasses) { 1000 + Double($0) / rate + latency }

        reportTimePitch("held start \(rate)x", "start sample \(start), \(landing.description), first click \(firstClick(in: output[0]) ?? -1)")
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
