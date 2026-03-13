// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-workspace

import AVFoundation
import Foundation
import SPFKBase
import SPFKTesting
import Testing
import Numerics

@testable import SPFKAudioNodes

@Suite(.serialized)
final class FaderTests: TestCaseModel {
    init() async throws {}

    @Test func create() async throws {
        var fader: Fader? = try await Fader(gain: 2)

        #expect(fader?.leftGain == 2)
        #expect(fader?.rightGain == 2)
        #expect(fader?.flipStereo == false)
        #expect(fader?.mixToMono == false)

        fader = nil
    }

    @Test func defaultGain() async throws {
        var fader: Fader? = try await Fader()

        #expect(fader?.leftGain == 1)
        #expect(fader?.rightGain == 1)
        #expect(fader?.gain == 1)

        fader = nil
    }

    @Test func gainSyncsLeftRight() async throws {
        var fader: Fader? = try await Fader(gain: 1)
        guard let f = fader else {
            Issue.record("Fader is nil")
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

        fader = nil
    }

    @Test func dBConversion() async throws {
        var fader: Fader? = try await Fader(gain: 1)
        guard let f = fader else {
            Issue.record("Fader is nil")
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

        fader = nil
    }

    @Test func stereoProperties() async throws {
        var fader: Fader? = try await Fader(gain: 1)
        guard let f = fader else {
            Issue.record("Fader is nil")
            return
        }

        f.flipStereo = true
        #expect(f.flipStereo == true)

        f.mixToMono = true
        #expect(f.mixToMono == true)

        fader = nil
    }

    @Test func independentChannelGain() async throws {
        var fader: Fader? = try await Fader(gain: 1)
        guard let f = fader else {
            Issue.record("Fader is nil")
            return
        }

        // Setting channels independently should not affect the other
        f.leftGain = 0.8
        #expect(f.leftGain == 0.8)
        #expect(f.rightGain == 1) // unchanged from init

        f.rightGain = 0.3
        #expect(f.rightGain == 0.3)
        #expect(f.leftGain == 0.8) // unchanged

        fader = nil
    }

    @Test func bypass() async throws {
        var fader: Fader? = try await Fader(gain: 1)
        guard let f = fader else {
            Issue.record("Fader is nil")
            return
        }

        #expect(f.isBypassed == false)
        f.isBypassed = true
        #expect(f.isBypassed == true)
        f.isBypassed = false
        #expect(f.isBypassed == false)

        fader = nil
    }
}
