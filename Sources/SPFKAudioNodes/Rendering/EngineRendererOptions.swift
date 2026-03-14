// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation

/// Configuration for offline audio engine rendering via ``EngineRenderer``.
public struct EngineRendererOptions: Sendable {
    /// The maximum number of PCM sample frames the engine produces in a single render call.
    let maximumFrameCount: AVAudioFrameCount

    /// When `true`, the renderer continues writing audio after the main render pass
    /// completes, capturing reverb tails and other effect decay until silence is detected.
    let renderUntilSilent: Bool

    /// RMS amplitude below which audio is considered silence during tail rendering.
    let silenceThreshold: Float

    /// Maximum duration (in seconds) of sub-threshold audio before the tail loop stops.
    /// The tail ends when this much continuous audio below ``silenceThreshold`` has been rendered.
    let underSilenceThresholdQuantity: TimeInterval

    /// Maximum duration (in seconds) of true-zero audio before the tail loop stops.
    /// Catches cases where the signal drops to exactly zero before reaching ``underSilenceThresholdQuantity``.
    let zeroSilenceQuantity: TimeInterval

    /// Absolute maximum tail duration (in seconds), regardless of silence detection.
    /// Acts as a safety cap to prevent infinite rendering.
    let maxTailToRender: TimeInterval

    /// When `true`, calls `disableManualRenderingMode()` on the engine after rendering completes.
    /// Set to `false` if you intend to perform additional renders without re-entering manual mode.
    let disableManualRenderingModeOnCompletion: Bool

    public init(
        maximumFrameCount: AVAudioFrameCount = 4096,
        renderUntilSilent: Bool = false,
        silenceThreshold: Float = 0.00005,
        underSilenceThresholdQuantity: TimeInterval = 2,
        zeroSilenceQuantity: TimeInterval = 0.3,
        maxTailToRender: TimeInterval = 60,
        disableManualRenderingModeOnCompletion: Bool = true
    ) {
        self.maximumFrameCount = maximumFrameCount
        self.renderUntilSilent = renderUntilSilent
        self.silenceThreshold = silenceThreshold
        self.underSilenceThresholdQuantity = underSilenceThresholdQuantity
        self.zeroSilenceQuantity = zeroSilenceQuantity
        self.maxTailToRender = maxTailToRender
        self.disableManualRenderingModeOnCompletion = disableManualRenderingModeOnCompletion
    }
}
