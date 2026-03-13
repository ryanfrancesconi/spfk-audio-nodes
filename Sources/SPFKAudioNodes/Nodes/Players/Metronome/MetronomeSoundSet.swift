// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-workspace

import AVFoundation
import SPFKBase

/// A set of click samples for use with ``Metronome``.
///
/// Each sound set contains three samples — bar (downbeat accent), beat, and
/// subdivision — loaded as `AVAudioPCMBuffer` in the standard processing format
/// (Float32, deinterleaved).
public struct MetronomeSoundSet: @unchecked Sendable {
    /// The accented downbeat click (first beat of each measure).
    public let bar: AVAudioPCMBuffer

    /// The regular beat click.
    public let beat: AVAudioPCMBuffer

    /// The subdivision click (eighth notes, sixteenth notes, etc.).
    public let subdivision: AVAudioPCMBuffer

    /// Creates a sound set from individual audio file URLs.
    ///
    /// - Parameters:
    ///   - barURL: URL to the bar (downbeat) click sample.
    ///   - beatURL: URL to the beat click sample.
    ///   - subdivisionURL: URL to the subdivision click sample.
    /// - Throws: If any file cannot be opened or read into a buffer.
    public init(barURL: URL, beatURL: URL, subdivisionURL: URL) throws {
        bar = try Self.loadBuffer(from: barURL)
        beat = try Self.loadBuffer(from: beatURL)
        subdivision = try Self.loadBuffer(from: subdivisionURL)
    }

    /// Creates a sound set from a directory using the naming convention
    /// `{prefix}_bar.wav`, `{prefix}_beat.wav`, `{prefix}_subdivision.wav`.
    ///
    /// - Parameters:
    ///   - directory: The directory containing the sample files.
    ///   - prefix: The filename prefix (e.g. `"drums"` or `"synth"`).
    /// - Throws: If the expected files are not found or cannot be read.
    public init(directory: URL, prefix: String) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        func find(_ component: String) throws -> URL {
            let target = "\(prefix)_\(component)"
            guard let url = contents.first(where: {
                $0.deletingPathExtension().lastPathComponent == target
            }) else {
                throw NSError(description: "Missing \(target) sample in \(directory.path)")
            }
            return url
        }

        try self.init(
            barURL: find("bar"),
            beatURL: find("beat"),
            subdivisionURL: find("subdivision")
        )
    }

    /// Returns the buffer for the given click type.
    public func buffer(for click: MetronomeClick) -> AVAudioPCMBuffer {
        switch click {
        case .bar: bar
        case .beat: beat
        case .subdivision: subdivision
        }
    }

    // MARK: - Built-in Sets

    /// The built-in drums sound set.
    public static func drums() throws -> MetronomeSoundSet {
        try builtIn(subdirectory: "Drums", prefix: "drums")
    }

    /// The built-in synth sound set.
    public static func synth() throws -> MetronomeSoundSet {
        try builtIn(subdirectory: "Synth", prefix: "synth")
    }

    // MARK: - Private

    private static func builtIn(subdirectory: String, prefix: String) throws -> MetronomeSoundSet {
        guard let directory = Bundle.module.url(
            forResource: subdirectory,
            withExtension: nil,
            subdirectory: "Metronome"
        ) else {
            throw NSError(description: "Missing built-in metronome sound set: \(subdirectory)")
        }
        return try MetronomeSoundSet(directory: directory, prefix: prefix)
    }

    private static func loadBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw NSError(description: "Failed to create buffer for \(url.lastPathComponent)")
        }

        try file.read(into: buffer, frameCount: frameCount)
        return buffer
    }
}
