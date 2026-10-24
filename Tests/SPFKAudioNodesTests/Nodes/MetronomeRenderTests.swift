// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKAudioNodes

@Suite(.tags(.engine), .serialized)
final class MetronomeRenderTests: TestCaseModel {
    private let sampleRate: Double = 48000
    private let blockSize: AVAudioFrameCount = 4096

    private func makeEngine(_ metronome: Metronome) throws -> AVAudioEngine {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let engine = AVAudioEngine()
        engine.attach(metronome.sourceNode)
        engine.connect(metronome.sourceNode, to: engine.outputNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: blockSize)
        try engine.start()
        return engine
    }

    /// The first channel of the next `frames` frames.
    private func render(_ engine: AVAudioEngine, frames: AVAudioFrameCount) throws -> [Float] {
        let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: blockSize))
        var result: [Float] = []
        var remaining = frames

        while remaining > 0 {
            try #require(try engine.renderOffline(min(remaining, blockSize), to: block) == .success)
            let data = try #require(block.floatChannelData)
            result += UnsafeBufferPointer(start: data[0], count: Int(block.frameLength))
            remaining -= block.frameLength
        }

        return result
    }

    @Test func playFromBeatBetweenRendersStartsOnItsFrame() async throws {
        let soundSet = try MetronomeSoundSet.drums()

        // 120 BPM at 48 kHz: 24000 frames a beat, so beat 0.5 is frame 12000 of a run from 0.
        let reference = Metronome(soundSet: soundSet, sampleRate: sampleRate)
        reference.bpm = Bpm(120)
        let referenceEngine = try makeEngine(reference)
        defer { referenceEngine.stop() }
        reference.play()
        let expected = try render(referenceEngine, frames: 36000)
        #expect(expected[24000...].contains { $0 != 0 })

        let metronome = Metronome(soundSet: soundSet, sampleRate: sampleRate)
        metronome.bpm = Bpm(120)
        let engine = try makeEngine(metronome)
        defer { engine.stop() }
        metronome.play()
        _ = try render(engine, frames: 1000)
        metronome.play(fromBeat: 0.5)
        let played = try render(engine, frames: 24000)

        #expect(played == Array(expected[12000 ..< 36000]))
    }

    @Test func playFromTimeMatchesPlayFromBeat() async throws {
        let soundSet = try MetronomeSoundSet.drums()

        let byBeat = Metronome(soundSet: soundSet, sampleRate: sampleRate)
        byBeat.bpm = Bpm(90)
        let byBeatEngine = try makeEngine(byBeat)
        defer { byBeatEngine.stop() }
        byBeat.play(fromBeat: 1.5)

        let byTime = Metronome(soundSet: soundSet, sampleRate: sampleRate)
        byTime.bpm = Bpm(90)
        let byTimeEngine = try makeEngine(byTime)
        defer { byTimeEngine.stop() }
        // 1.5 beats at 90 BPM.
        byTime.play(time: 1.0)

        let expected = try render(byBeatEngine, frames: 48000)
        #expect(expected.contains { $0 != 0 })
        #expect(try render(byTimeEngine, frames: 48000) == expected)
    }
}
