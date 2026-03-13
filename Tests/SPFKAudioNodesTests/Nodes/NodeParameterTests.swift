// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import AVFoundation
import Foundation
import SPFKBase
import Testing

@testable import SPFKAudioNodes

struct NodeParameterTests {
    static let testDef = NodeParameterDef(
        identifier: "testParam",
        name: "Test Parameter",
        address: 0,
        defaultValue: 0.5,
        range: 0 ... 1,
        unit: .linearGain
    )

    @Test func unassociatedDefaults() {
        let param = NodeParameter(Self.testDef)

        // Before association, should return def defaults without crashing
        #expect(param.parameter == nil)
        #expect(param.value == 0.5) // def.defaultValue
        #expect(param.minValue == 0)
        #expect(param.maxValue == 1)
        #expect(param.range == 0 ... 1)
    }

    @Test func unassociatedValueSetDoesNotCrash() {
        let param = NodeParameter(Self.testDef)

        // Setting value when parameter is nil should be a no-op, not a crash
        param.value = 0.8
        #expect(param.value == 0.5) // still returns def default since parameter is nil
    }

    @Test func unassociatedBoolValue() {
        let param = NodeParameter(Self.testDef)

        // boolValue derives from value, which returns def.defaultValue (0.5)
        #expect(param.boolValue == false)
    }

    @Test func unassociatedRampDoesNotCrash() {
        let param = NodeParameter(Self.testDef)

        // ramp should silently return when parameter is nil
        param.ramp(to: 1.0, duration: 0.1, sampleRate: 44100)
    }

    @Test func unassociatedBeginEndTouchDoesNotCrash() {
        let param = NodeParameter(Self.testDef)

        // These already used optional chaining, but verify they don't crash
        param.beginTouch(value: 0.5)
        param.endTouch(value: 0.5)
    }

    @Test func defProperties() {
        let def = NodeParameterDef(
            identifier: "volume",
            name: "Volume",
            address: 42,
            defaultValue: 0.75,
            range: 0 ... 2,
            unit: .linearGain
        )

        let param = NodeParameter(def)
        #expect(param.def.identifier == "volume")
        #expect(param.def.name == "Volume")
        #expect(param.def.address == 42)
        #expect(param.def.defaultValue == 0.75)
        #expect(param.def.range == 0 ... 2)
    }

    @Test func associateThrowsOnMissingParameterTree() {
        let param = NodeParameter(Self.testDef)
        let node = AVAudioPlayerNode()

        // AVAudioPlayerNode has no parameter tree, so associate should throw
        #expect(throws: (any Error).self) {
            try param.associate(with: node)
        }
    }
}
