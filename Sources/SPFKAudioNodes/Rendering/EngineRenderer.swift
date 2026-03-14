// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import Accelerate
import AVFoundation
import SPFKBase

/// Renders an `AVAudioEngine` graph to an audio file in offline (manual rendering) mode.
///
/// The renderer switches the engine into manual rendering mode, executes a caller-supplied
/// `prerender` action (typically `player.play()`), pulls frames through the graph until the
/// requested duration is reached, then optionally captures the reverb/effect tail via
/// silence detection. Progress is reported through a callback.
///
/// All mutable state is actor-isolated. Use ``render(to:duration:options:prerender:postrender:progressHandler:disableManualRenderingModeOnCompletion:)``
/// to start a render, and ``cancelRender()`` to abort an in-progress render.
public actor EngineRenderer {
    /// The audio engine whose node graph will be rendered offline.
    let engine: AVAudioEngine

    /// Whether to exit manual rendering mode when the render completes or is cancelled.
    var disableManualRenderingModeOnCompletion: Bool = true

    /// The currently executing render task, if any.
    var renderTask: Task<Void, Error>?

    /// Destination file for the rendered audio.
    var audioFile: AVAudioFile?

    /// Total duration (in seconds) of audio to render in the main pass.
    var duration: TimeInterval = 0

    /// Rendering configuration (frame count, silence detection, tail behavior).
    var options: EngineRendererOptions = .init()

    /// Called before the render loop begins — typically starts playback on player nodes.
    var prerender: (@Sendable () throws -> Void)?

    /// Called after the main render loop completes — typically stops player nodes.
    var postrender: (@Sendable () throws -> Void)?

    /// Called periodically with a `0.0...1.0` progress value during rendering.
    var progressHandler: (@Sendable (UnitInterval) -> Void)?

    /// Total number of sample frames to render, derived from ``duration`` and sample rate.
    private var targetSamples: AVAudioFramePosition = 0

    /// The engine output node's maximum frames per render slice.
    var maxFramePerSlice: AVAudioFrameCount {
        engine.outputNode.auAudioUnit.maximumFramesToRender
    }

    /// The PCM format used for rendering — prefers the audio file's processing format,
    /// falling back to the engine's manual rendering format.
    var manualRenderingFormat: AVAudioFormat {
        audioFile?.processingFormat ?? engine.manualRenderingFormat
    }

    public init(engine: AVAudioEngine) {
        self.engine = engine
    }

    deinit {
        Log.debug("- { \(self) }")
    }
}

extension EngineRenderer {
    /// Renders the engine's node graph to a file in offline mode.
    ///
    /// - Parameters:
    ///   - audioFile: The destination file to write rendered audio into.
    ///   - duration: Length of audio to render (in seconds). Must be positive.
    ///   - options: Rendering configuration (frame count, silence tail detection).
    ///   - prerender: Called before the render loop — typically starts player nodes.
    ///   - postrender: Called after the main render loop — typically stops player nodes.
    ///   - progressHandler: Called periodically with a `0.0...1.0` progress value.
    ///   - disableManualRenderingModeOnCompletion: Whether to exit manual rendering mode when done.
    public func render(
        to audioFile: AVAudioFile,
        duration: TimeInterval,
        options: EngineRendererOptions = .init(),
        prerender: @escaping @Sendable () throws -> Void, // play()
        postrender: (@Sendable () throws -> Void)?, // stop()
        progressHandler: (@Sendable (UnitInterval) -> Void)? = nil,
        disableManualRenderingModeOnCompletion: Bool = true
    ) async throws {
        guard duration > 0 else {
            throw NSError(description: "duration needs to be a positive value")
        }

        self.audioFile = audioFile
        self.options = options
        self.duration = duration
        self.prerender = prerender
        self.postrender = postrender
        self.progressHandler = progressHandler
        self.disableManualRenderingModeOnCompletion = disableManualRenderingModeOnCompletion

        try await start()
    }

    /// Convenience that creates an `AVAudioFile` from a URL and settings, then renders to it.
    ///
    /// - Parameters:
    ///   - url: The destination file URL.
    ///   - settings: Audio file settings dictionary (e.g. sample rate, bit depth, format).
    ///   - duration: Length of audio to render (in seconds).
    ///   - options: Rendering configuration (frame count, silence tail detection).
    ///   - prerender: Called before the render loop — typically starts player nodes.
    ///   - postrender: Called after the main render loop — typically stops player nodes.
    ///   - progressHandler: Called periodically with a `0.0...1.0` progress value.
    ///   - disableManualRenderingModeOnCompletion: Whether to exit manual rendering mode when done.
    public func render(
        to url: URL,
        settings: [String: Any],
        duration: Double,
        options: EngineRendererOptions,
        prerender: @escaping (@Sendable () throws -> Void),
        postrender: (@Sendable () throws -> Void)?,
        progressHandler: (@Sendable (UnitInterval) -> Void)?,
        disableManualRenderingModeOnCompletion: Bool = true
    ) async throws {
        let audioFile = try AVAudioFile(forWriting: url, settings: settings)

        try await render(
            to: audioFile,
            duration: duration,
            options: options,
            prerender: prerender,
            postrender: postrender,
            progressHandler: progressHandler,
            disableManualRenderingModeOnCompletion: disableManualRenderingModeOnCompletion
        )
    }

    /// Cancels an in-progress render. The partially-written output file is deleted.
    public func cancelRender() async {
        guard let renderTask else {
            Log.error("renderTask is nil")
            return
        }

        Log.debug("* Canceling...")

        renderTask.cancel()
    }
}

extension EngineRenderer {
    /// Kicks off the render task and awaits its result, cleaning up on completion or cancellation.
    private func start() async throws {
        guard let audioFile else {
            throw NSError(description: "audioFile is nil")
        }

        renderTask?.cancel()
        renderTask = Task<Void, Error> {
            try await setupEngine()
        }

        defer {
            if disableManualRenderingModeOnCompletion, engine.isInManualRenderingMode {
                engine.disableManualRenderingMode()
            }

            Log.debug("*  Complete")
            renderTask = nil
        }

        guard let renderTask else { return }

        let result = await renderTask.result

        guard !renderTask.isCancelled else {
            Log.debug("* renderTask.isCancelled, attempting to remove file at \(audioFile.url.path)")
            try? audioFile.url.delete()
            throw CancellationError()
        }

        switch result {
        case .success:
            Log.debug("* OK, rendered \(audioFile.length) samples")

        case let .failure(error):
            throw error
        }
    }

    /// Switches the engine into manual rendering mode, starts it, and runs the render loop.
    private func setupEngine() async throws {
        guard let audioFile else {
            throw NSError(description: "audioFile is nil")
        }

        defer {
            Log.debug("*  Stopping engine, wrote", audioFile.duration, "seconds to file")
            engine.stop()
        }

        // Engine can't be running when switching to offline render mode.
        engine.stop()

        if !engine.isInManualRenderingMode || audioFile.processingFormat != engine.manualRenderingFormat {
            let maxFrameCount: AVAudioFrameCount = UInt32(duration * audioFile.processingFormat.sampleRate) / 100

            try engine.enableManualRenderingMode(
                .offline,
                format: manualRenderingFormat,
                maximumFrameCount: maxFrameCount
            )
        }

        assert(engine.manualRenderingFormat == audioFile.processingFormat)

        // This resets the sampleTime of offline rendering to 0.
        engine.reset()

        Log.debug("Starting engine...")

        try engine.start()

        try write()
    }

    /// Main render loop: calls prerender, pulls frames until `targetSamples` is reached,
    /// calls postrender, then optionally renders the tail.
    private func write() throws {
        guard let audioFile else {
            throw NSError(description: "audioFile is nil")
        }

        guard let prerender else {
            throw NSError(description: "prerender is nil")
        }

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: engine.manualRenderingMaximumFrameCount
            )
        else {
            throw NSError(description: "Couldn't create buffer with format \(engine.manualRenderingFormat)")
        }

        // MARK: - Render Loop

        targetSamples = AVAudioFramePosition(
            duration * manualRenderingFormat.sampleRate
        )

        assert(targetSamples > 0)

        // This is to prepare the nodes for playing, i.e player.play()
        try prerender()

        while engine.manualRenderingSampleTime < targetSamples {
            let frameCount = targetSamples - engine.manualRenderingSampleTime
            let framesToRender = min(AVAudioFrameCount(frameCount), buffer.frameCapacity)
            try write(buffer: buffer, framesToRender: framesToRender)

            let rawProgress = UnitInterval(audioFile.framePosition) / Double(targetSamples)

            progressHandler?(
                min(rawProgress, 1.0)
            )

            let isComplete = rawProgress >= 1

            if isComplete {
                break
            }
        }

        // MARK: - Stop

        if let postrender {
            Log.debug("* Triggering postrender action")
            try postrender()
        }

        if options.renderUntilSilent {
            try writeTail()
        }
    }

    /// Renders a single slice of frames into the buffer and writes it to the output file.
    private func write(buffer: AVAudioPCMBuffer, framesToRender: AVAudioFrameCount) throws {
        guard let audioFile else {
            throw NSError(description: "audioFile is nil")
        }

        let status = try engine.renderOffline(framesToRender, to: buffer)

        switch status {
        case .success:
            try audioFile.write(from: buffer)

        case .cannotDoInCurrentContext:
            throw NSError(description: ".cannotDoInCurrentContext")

        case .insufficientDataFromInputNode:
            throw NSError(description: ".insufficientDataFromInputNode")

        case .error:
            throw NSError(description: "There was an error rendering to \(audioFile.url.path)")

        @unknown default:
            throw NSError(description: "Unknown render result: \(status)")
        }
    }
}

// MARK: - Tail Loop

extension EngineRenderer {
    /// Continues rendering after the main pass to capture reverb/effect decay.
    /// Stops when silence is detected or ``EngineRendererOptions/maxTailToRender`` is reached.
    private func writeTail() throws {
        Log.debug("Entering audio tail loop...")

        let framesToRender: AVAudioFrameCount = maxFramePerSlice

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: framesToRender
            )
        else {
            throw NSError(description: "Couldn't create buffer with format \(engine.manualRenderingFormat)")
        }

        var silenceRendered: TimeInterval = 0
        var zerosRendered: TimeInterval = 0

        while true {
            try Task.checkCancellation()

            try write(buffer: buffer, framesToRender: framesToRender)

            let rms = try rms(for: buffer)

            if rms < options.silenceThreshold {
                silenceRendered += (Double(buffer.frameLength) / buffer.format.sampleRate)

                if rms == 0 {
                    zerosRendered = silenceRendered
                }

                if zerosRendered > options.zeroSilenceQuantity { break }

                if silenceRendered > options.underSilenceThresholdQuantity { break }
                if silenceRendered > options.maxTailToRender { break }
            }
        }

        Log.debug("Rendered an extra", silenceRendered, "seconds")
    }

    /// Computes the average RMS amplitude across all channels in the buffer using Accelerate.
    private func rms(for buffer: AVAudioPCMBuffer) throws -> Float {
        let channelCount = Int(buffer.format.channelCount)

        guard let data = buffer.floatChannelData else {
            return 0
        }

        var rms: Float = 0.0

        for i in 0 ..< channelCount {
            var channelRms: Float = 0.0

            vDSP_rmsqv(data[i], 1, &channelRms, vDSP_Length(buffer.frameLength))
            rms += abs(channelRms)
        }

        let value = rms / Float(channelCount)

        return value
    }
}
