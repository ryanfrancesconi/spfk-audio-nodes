// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKBase
import SPFKTesting
import Testing
import Numerics

@testable import SPFKAudioNodes

@Suite
final class ChannelGainTests: TestCaseModel {
    init() async throws {}

    @Test func create() async throws {
        var channelGain: ChannelGain? = try await ChannelGain(gain: 2)

        #expect(channelGain?.leftGain == 2)
        #expect(channelGain?.rightGain == 2)
        #expect(channelGain?.flipStereo == false)
        #expect(channelGain?.mixToMono == false)

        channelGain = nil
    }

    @Test func defaultGain() async throws {
        var channelGain: ChannelGain? = try await ChannelGain()

        #expect(channelGain?.leftGain == 1)
        #expect(channelGain?.rightGain == 1)
        #expect(channelGain?.gain == 1)

        channelGain = nil
    }

    @Test func gainSyncsLeftRight() async throws {
        var channelGain: ChannelGain? = try await ChannelGain(gain: 1)
        guard let f = channelGain else {
            Issue.record("ChannelGain is nil")
            return
        }

        // Setting gain should update both channels
        f.gain = 0.5
        #expect(f.leftGain == 0.5)
        #expect(f.rightGain == 0.5)
        #expect(f.gain == 0.5)

        f.gain = 2
        #expect(f.leftGain == 2)
        #expect(f.rightGain == 2)

        channelGain = nil
    }

    @Test func dBConversion() async throws {
        var channelGain: ChannelGain? = try await ChannelGain(gain: 1)
        guard let f = channelGain else {
            Issue.record("ChannelGain is nil")
            return
        }

        // Unity gain = 0 dB
        #expect(f.dB == 0)

        // Set via dB
        f.dB = 6
        #expect(f.gain.isApproximatelyEqual(to: AUValue(6).linearValue, absoluteTolerance: 0.001))

        // Set to -infinity dB (gain 0)
        f.gain = 0
        #expect(f.dB == -Float.infinity)

        channelGain = nil
    }

    @Test func stereoProperties() async throws {
        var channelGain: ChannelGain? = try await ChannelGain(gain: 1)
        guard let f = channelGain else {
            Issue.record("ChannelGain is nil")
            return
        }

        f.flipStereo = true
        #expect(f.flipStereo == true)

        f.mixToMono = true
        #expect(f.mixToMono == true)

        channelGain = nil
    }

    @Test func independentChannelGain() async throws {
        var channelGain: ChannelGain? = try await ChannelGain(gain: 1)
        guard let f = channelGain else {
            Issue.record("ChannelGain is nil")
            return
        }

        // Setting channels independently should not affect the other
        f.leftGain = 0.8
        #expect(f.leftGain == 0.8)
        #expect(f.rightGain == 1) // unchanged from init

        f.rightGain = 0.3
        #expect(f.rightGain == 0.3)
        #expect(f.leftGain == 0.8) // unchanged

        channelGain = nil
    }

    @Test func bypass() async throws {
        var channelGain: ChannelGain? = try await ChannelGain(gain: 1)
        guard let f = channelGain else {
            Issue.record("ChannelGain is nil")
            return
        }

        #expect(f.isBypassed == false)
        f.isBypassed = true
        #expect(f.isBypassed == true)
        f.isBypassed = false
        #expect(f.isBypassed == false)

        channelGain = nil
    }

    @Test func parameterUnitsMatchTheirDefinitions() async throws {
        let channelGain = try await ChannelGain()

        for param in channelGain.parameters {
            #expect(param.parameter?.unit == param.def.unit, "\(param.def.identifier)")
        }

        #expect(channelGain.$leftGain.parameter?.unit == .linearGain)
        #expect(channelGain.$rightGain.parameter?.unit == .linearGain)
        #expect(channelGain.$monoSource.parameter?.unit == .indexed)
    }
}
