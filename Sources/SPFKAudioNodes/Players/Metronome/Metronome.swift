// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import os
import SPFKAudioBase
import SPFKAUHost
import SPFKBase

/// A sample-accurate metronome that generates click audio via an `AVAudioSourceNode`.
///
/// The render block tracks a running sample counter and inserts click samples
/// at beat boundaries computed from the current BPM, beats per bar, and
/// subdivision count. Because it uses `AVAudioSourceNode`, it works with both
/// realtime playback and offline rendering (`engine.renderOffline`).
///
/// Attach to a mixer via ``AudioEngineNodeAU/avAudioNode`` and call
/// ``play()``/``stop()`` in sync with your transport.
///
/// ```swift
/// let soundSet = try MetronomeSoundSet(directory: sampleDir, prefix: "drums")
/// let metronome = try Metronome(soundSet: soundSet, sampleRate: 48000)
/// // attach metronome.sourceNode to mixer...
/// metronome.bpm = Bpm(120)!
/// metronome.play()
/// ```
public final class Metronome: @unchecked Sendable {
    /// The source node that generates click audio. Connect this to a mixer.
    public let sourceNode: AVAudioSourceNode

    // MARK: - Lock-protected state

    /// Shared mutable state accessed from both the render thread and the
    /// calling thread. Stored in a separate class so the render block can
    /// capture it without capturing `self`.
    private final class State: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock()
        var bpm: Double = 120
        var beatsPerBar: Int = 4
        var subdivisions: Int = 1
        var isMuted: Bool = false
        var isPlaying: Bool = false
        var samplePosition: Int64 = 0
    }

    private let state = State()

    /// The tempo in beats per minute. Changes take effect at the next beat.
    public var bpm: Bpm? {
        get { Bpm(state.lock.withLock { state.bpm }) }
        set {
            guard let newValue else { return }
            state.lock.withLock { state.bpm = newValue.rawValue }
        }
    }

    /// Number of beats per bar (time signature numerator). Default is 4.
    public var beatsPerBar: Int {
        get { state.lock.withLock { state.beatsPerBar } }
        set { state.lock.withLock { state.beatsPerBar = max(1, newValue) } }
    }

    /// Number of subdivisions per beat.
    /// 1 = quarter notes only,
    /// 2 = eighth notes,
    /// 4 = sixteenth notes, etc.
    ///
    /// Default is 1.
    public var subdivisions: Int {
        get { state.lock.withLock { state.subdivisions } }
        set { state.lock.withLock { state.subdivisions = max(1, newValue) } }
    }

    /// Mutes audio output without stopping the metronome.
    /// The sample counter continues advancing so beat position stays in sync.
    public var isMuted: Bool {
        get { state.lock.withLock { state.isMuted } }
        set { state.lock.withLock { state.isMuted = newValue } }
    }

    /// Whether the metronome is currently generating audio.
    public var isPlaying: Bool {
        state.lock.withLock { state.isPlaying }
    }

    // MARK: - Immutable after init

    private let sampleRate: Double

    // MARK: - Init

    /// Creates a metronome with the given sound set and sample rate.
    ///
    /// - Parameters:
    ///   - soundSet: The click samples to use.
    ///   - sampleRate: The audio engine's sample rate.
    public init(soundSet: MetronomeSoundSet, sampleRate: Double) {
        self.sampleRate = sampleRate

        // Extract mono float data from each buffer (immutable after init)
        let barSamples = Self.extractSamples(from: soundSet.bar)
        let beatSamples = Self.extractSamples(from: soundSet.beat)
        let subdivisionSamples = Self.extractSamples(from: soundSet.subdivision)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        // Capture the state object and sample arrays — not `self`.
        let state = state

        // AVAudioSourceNode calls this render block on the realtime audio thread
        // each time the engine needs more audio. The block must fill `outputData`
        // with `frameCount` samples and return `noErr`.
        //
        // Swift is safe here because nothing in the block allocates on the heap:
        // - The [Float] sample arrays are captured at init and never mutated,
        //   so element access is a direct pointer dereference (no COW copy).
        // - OSAllocatedUnfairLock is a non-blocking spinlock that never enters
        //   the kernel — the one lock type acceptable on the audio thread.
        // - All arithmetic uses stack-local scalars and UnsafePointer math.
        // - memset/memcpy are C functions with no Swift runtime overhead.
        // No swift_allocObject, no objc_msgSend, no autorelease pools.
        sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, outputData in
            // Snapshot all mutable state in a single lock acquisition to avoid
            // holding the lock during the per-frame loop below.
            let (bpm, beatsPerBar, subdivisions, isMuted, isPlaying, samplePosition): (Double, Int, Int, Bool, Bool, Int64) = state.lock.withLock {
                (state.bpm, state.beatsPerBar, state.subdivisions, state.isMuted, state.isPlaying, state.samplePosition)
            }

            let ablPointer = UnsafeMutableAudioBufferListPointer(outputData)

            // Not playing — zero the buffers. The output buffers contain
            // uninitialized memory, so we must write zeros explicitly;
            // setting isSilence alone is only a hint and doesn't guarantee
            // the engine will clear the buffers for us.
            guard isPlaying, bpm > 0 else {
                for buffer in ablPointer {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                isSilence.pointee = true
                return noErr
            }

            // Muted — zero the buffers but keep advancing the sample counter
            // so beat position stays in sync with the transport. When unmuted
            // mid-playback the clicks resume at the correct beat.
            if isMuted {
                for buffer in ablPointer {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                state.lock.withLock {
                    state.samplePosition += Int64(frameCount)
                }
                isSilence.pointee = true
                return noErr
            }

            // Total clicks per bar (e.g. 4 beats * 2 subdivisions = 8 clicks).
            let clicksPerBar = beatsPerBar * subdivisions

            // Number of samples between consecutive clicks at the current tempo.
            // At 120 BPM with subdivisions=1: 48000 * 60 / 120 / 1 = 24000 samples.
            let samplesPerClick = sampleRate * 60.0 / bpm / Double(subdivisions)

            guard let ch0Ptr = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = true
                return noErr
            }

            // Fill the first channel sample-by-sample. For each frame we figure
            // out which click we're in and how far into that click's sample data
            // we are, then write the corresponding sample (or silence if past
            // the end of the click waveform).
            for frame in 0 ..< Int(frameCount) {
                let pos = samplePosition + Int64(frame)

                // Which click number we're on (monotonically increasing).
                let clickIndex = Int(Double(pos) / samplesPerClick)

                // How many samples into the current click waveform.
                let positionInClick = Int(Double(pos) - Double(clickIndex) * samplesPerClick)

                // Pick the right sample set based on where this click falls
                // within the bar: first click = bar accent, beat boundaries =
                // regular beat, everything else = subdivision tick.
                let clickInBar = clickIndex % clicksPerBar
                let samples: [Float] = if clickInBar == 0 {
                    barSamples
                } else if clickInBar % subdivisions == 0 {
                    beatSamples
                } else {
                    subdivisionSamples
                }

                if positionInClick >= 0, positionInClick < samples.count {
                    ch0Ptr[frame] = samples[positionInClick]
                } else {
                    ch0Ptr[frame] = 0
                }
            }

            // Duplicate channel 0 to all remaining channels (stereo: L=R).
            let byteCount = Int(frameCount) * MemoryLayout<Float>.size
            for i in 1 ..< ablPointer.count {
                if let dest = ablPointer[i].mData {
                    memcpy(dest, ch0Ptr, byteCount)
                }
            }

            // Advance the running sample counter so the next render call
            // picks up where this one left off.
            state.lock.withLock {
                state.samplePosition += Int64(frameCount)
            }

            isSilence.pointee = false
            return noErr
        }
    }

    // MARK: - Transport

    /// Start generating click audio. Resets the sample counter to zero.
    public func play() {
        state.lock.withLock {
            state.samplePosition = 0
            state.isPlaying = true
        }
    }

    /// Start generating click audio from a time offset in seconds.
    /// Converts the time to a beat offset using the current BPM.
    public func play(time: TimeInterval) {
        let beatsPerSecond = state.bpm / 60.0
        let beatOffset = time * beatsPerSecond
        play(fromBeat: beatOffset)
    }

    /// Start generating click audio from a specific beat offset.
    ///
    /// - Parameter beatOffset: The beat position to start from (0-based).
    public func play(fromBeat beatOffset: Double) {
        state.lock.withLock {
            let samplesPerBeat = sampleRate * 60.0 / state.bpm
            state.samplePosition = Int64(beatOffset * samplesPerBeat)
            state.isPlaying = true
        }
    }

    /// Stop generating click audio.
    public func stop() {
        state.lock.withLock {
            state.isPlaying = false
        }
    }

    // MARK: - Private

    /// Extracts mono Float32 sample data from a buffer.
    /// If the buffer is stereo, uses only the first channel.
    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }
}
