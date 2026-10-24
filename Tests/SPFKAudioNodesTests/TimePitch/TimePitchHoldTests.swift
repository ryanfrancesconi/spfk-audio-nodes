// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

/// A held start's edges, offline: what replaces, survives or drops a hold, and the upstream
/// timeline across one.
@Suite(.tags(.engine), .serialized)
final class TimePitchHoldTests: TestCaseModel {
    private let sampleRate = TimePitchRig.sampleRate
    private let rate = 0.5
    private let clickSpacing = 4800

    private func makeRig() async throws -> TimePitchRig {
        let rig = try await TimePitchRig { [rate] in $0.rate = AUValue(rate) }
        _ = try rig.render(frames: 20 * 512)
        return rig
    }

    private func schedule(on rig: TimePitchRig) throws {
        let input = try TimePitchRig.makeClicks(frames: Int(sampleRate), every: clickSpacing, first: clickSpacing / 2)
        rig.player.scheduleBuffer(input, at: AVAudioTime(sampleTime: 0, atRate: sampleRate), completionHandler: nil)
    }

    /// The worst distance of each click from `heard + p / rate`, over `output` rendered from `renderedFrom`.
    private func worstLanding(_ output: [Float], renderedFrom: Int64, heard: Int64, rate: Double) -> Int {
        let clicks = stride(from: clickSpacing / 2, to: Int(sampleRate), by: clickSpacing)
        var worst = 0
        for click in clicks {
            let predicted = Int(heard - renderedFrom) + Int((Double(click) / rate).rounded())
            guard predicted + 1200 < output.count else { continue }
            worst = max(worst, abs(peakFrame(in: output, near: predicted, radius: 1200) - predicted))
        }
        return worst
    }

    @Test func aLaterHoldReplacesAnEarlierOne() async throws {
        let rig = try await makeRig()
        let now = rig.engine.manualRenderingSampleTime
        try schedule(on: rig)

        _ = rig.timePitch.holdStart(untilSampleTime: now + 1000)
        let heard = now + rig.latencyFrames(atRate: rate) + 6000
        try rig.startHeld(heardAt: heard, rate: rate)

        let output = try rig.render(frames: Int(heard - now) + 2 * Int(sampleRate) + 2400)
        #expect(worstLanding(output[0], renderedFrom: now, heard: heard, rate: rate) <= 2)
    }

    @Test func anEarlierHoldReplacesALaterOne() async throws {
        let rig = try await makeRig()
        let now = rig.engine.manualRenderingSampleTime
        try schedule(on: rig)

        _ = rig.timePitch.holdStart(untilSampleTime: now + 48000)
        let heard = now + rig.latencyFrames(atRate: rate) + 1000
        try rig.startHeld(heardAt: heard, rate: rate)

        let output = try rig.render(frames: Int(heard - now) + 2 * Int(sampleRate) + 2400)
        #expect(worstLanding(output[0], renderedFrom: now, heard: heard, rate: rate) <= 2)
    }

    @Test func resetDuringAHoldLeavesItInPlace() async throws {
        let rig = try await makeRig()
        let now = rig.engine.manualRenderingSampleTime
        try schedule(on: rig)
        let heard = now + rig.latencyFrames(atRate: rate) + 3000
        try rig.startHeld(heardAt: heard, rate: rate)

        var output = try rig.render(frames: 1024)
        rig.timePitch.avAudioNode.auAudioUnit.reset()
        output[0] += try rig.render(frames: Int(heard - now) + 2 * Int(sampleRate) + 2400)[0]

        #expect(worstLanding(output[0], renderedFrom: now, heard: heard, rate: rate) <= 2)
    }

    /// Bypassing during the hold keeps its release time; with no latency, source 0 is heard there.
    @Test func bypassDuringAHoldLeavesItInPlace() async throws {
        let rig = try await makeRig()
        let now = rig.engine.manualRenderingSampleTime
        try schedule(on: rig)
        let latency = rig.latencyFrames(atRate: rate)
        let heard = now + latency + 3000
        try rig.startHeld(heardAt: heard, rate: rate)

        var output = try rig.render(frames: 1024)
        rig.timePitch.isBypassed = true
        output[0] += try rig.render(frames: Int(heard - now) + Int(sampleRate) + 2400)[0]

        #expect(worstLanding(output[0], renderedFrom: now, heard: heard - latency, rate: 1) == 0)
    }

    @Test func aHoldAlreadyPastStartsAtTheNextBlock() async throws {
        let rig = try await makeRig()
        let now = rig.engine.manualRenderingSampleTime
        try schedule(on: rig)

        let upstream = try #require(rig.timePitch.holdStart(untilSampleTime: now - 1000))
        rig.player.play(at: AVAudioTime(sampleTime: upstream, atRate: sampleRate))

        let heard = now + rig.latencyFrames(atRate: rate)
        let output = try rig.render(frames: Int(heard - now) + 2 * Int(sampleRate) + 2400)
        #expect(worstLanding(output[0], renderedFrom: now, heard: heard, rate: rate) <= 2)
    }

    /// The upstream time a hold returned counts on the old resources' timeline, so new ones drop
    /// it and the node pulls at the rate from its first block.
    @Test func reallocatingRenderResourcesDropsAHold() async throws {
        let rig = try await makeRig()
        let now = rig.engine.manualRenderingSampleTime
        _ = rig.timePitch.holdStart(untilSampleTime: now + 48000)

        let unit = rig.timePitch.avAudioNode.auAudioUnit
        unit.deallocateRenderResources()
        try unit.allocateRenderResources()

        let pulledBefore = rig.timePitch.inputFramesPulled
        _ = try rig.render(frames: 20 * 512)
        #expect(rig.timePitch.inputFramesPulled - pulledBefore == Int64(Double(20 * 512) * rate))
    }

    /// Every pull of the upstream continues from the last, through a hold, its release, and a
    /// second hold made while playing: no upstream node is handed a time twice or skipped past.
    @Test func theUpstreamTimelineNeverJumps() async throws {
        final class Pulls: @unchecked Sendable {
            var times: [(sampleTime: Double, frames: AUAudioFrameCount)] = []
        }
        let rig = try await makeRig()
        let pulls = Pulls()
        let token = rig.mixer.auAudioUnit.token { flags, timestamp, frames, _ in
            if flags.contains(.unitRenderAction_PostRender) { pulls.times.append((timestamp.pointee.mSampleTime, frames)) }
        }
        defer { rig.mixer.auAudioUnit.removeRenderObserver(token) }

        let now = rig.engine.manualRenderingSampleTime
        try schedule(on: rig)
        try rig.startHeld(heardAt: now + rig.latencyFrames(atRate: rate) + 3000, rate: rate)
        _ = try rig.render(frames: 30 * 512)

        rig.player.stop()
        try schedule(on: rig)
        try rig.startHeld(heardAt: rig.engine.manualRenderingSampleTime, rate: rate)
        _ = try rig.render(frames: 30 * 512)

        #expect(pulls.times.count > 60)
        let jumps = zip(pulls.times, pulls.times.dropFirst()).filter { $0.sampleTime + Double($0.frames) != $1.sampleTime }
        #expect(jumps.isEmpty, "\(jumps.prefix(4))")
    }
}
