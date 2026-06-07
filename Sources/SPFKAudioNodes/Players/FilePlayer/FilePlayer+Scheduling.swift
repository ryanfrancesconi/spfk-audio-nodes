// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAudioBase
import SPFKBase

extension FilePlayer {
    public func schedule(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil,
        when scheduledTime: TimeInterval = 0,
        hostTime: UInt64? = nil,
        onComplete: (@Sendable () -> Void)? = nil
    ) throws {
        let hostTime = hostTime ?? mach_absolute_time()

        guard let audioTime: AVAudioTime = audioTime(scheduledTime: scheduledTime, hostTime: hostTime) else {
            throw NSError(file: #file, function: #function, description: "Failed to create scheduled time")
        }

        try schedule(from: startingTime, to: endingTime, audioTime: audioTime, onComplete: onComplete)
    }

    public func schedule(
        from startingTime: TimeInterval? = nil,
        to endingTime: TimeInterval? = nil,
        audioTime: AVAudioTime,
        onComplete: (@Sendable () -> Void)? = nil
    ) throws {
        // Only update the time range if the requested bounds differ from current
        let requestedStart = startingTime ?? 0
        let requestedEnd = endingTime ?? duration ?? 0

        if playbackRange?.lowerBound != requestedStart || playbackRange?.upperBound != requestedEnd {
            try updateTimeRange(from: startingTime, to: endingTime)
        }

        try scheduleSegment(at: audioTime, onComplete: onComplete)
    }

    /// a segment must be scheduled before you can play
    private func scheduleSegment(at audioTime: AVAudioTime?, onComplete: (@Sendable () -> Void)? = nil) throws {
        guard let audioFile else {
            throw NSError(file: #file, function: #function, description: "No audio file is loaded")
        }

        guard let playbackRange else {
            throw NSError(file: #file, function: #function, description: "invalid edit range")
        }

        lastScheduledTime = audioTime

        let sampleRate: Double = audioFile.fileFormat.sampleRate
        let startFrame = AVAudioFramePosition(playbackRange.lowerBound * sampleRate)
        let endFrame = AVAudioFramePosition(playbackRange.upperBound * sampleRate)
        let totalFrames = endFrame - startFrame

        guard totalFrames > 0 else {
            throw NSError(file: #file, function: #function, description: "Unable to schedule file. totalFrames to play: \(totalFrames). audioFile.length: \(audioFile.length)")
        }

        let frameCount = AVAudioFrameCount(totalFrames)

        let expectedHostTime: UInt64? = renderingMode != .offline
            ? audioTime.map { $0.offset(seconds: Double(frameCount) / sampleRate).hostTime }
            : nil

        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: audioTime,
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [onComplete] _ in
                guard let onComplete else { return }
                if let expectedHostTime {
                    guard mach_absolute_time() >= expectedHostTime else { return }
                }
                onComplete()
            }
        )

        playerNode.prepare(withFrameCount: frameCount)
    }

    // MARK: - Helpers

    private func audioTime(scheduledTime: TimeInterval, hostTime: UInt64) -> AVAudioTime? {
        if renderingMode == .offline {
            guard let sampleRate else { return nil }

            // needs to be a sample based AVAudioTime for offline rendering
            let sampleTime = AVAudioFramePosition(scheduledTime * sampleRate)

            let sampleAVTime = AVAudioTime(
                hostTime: hostTime,
                sampleTime: sampleTime,
                atRate: sampleRate
            )

            return sampleAVTime

        } else {
            return AVAudioTime(hostTime: hostTime).offset(seconds: scheduledTime)
        }
    }
}
