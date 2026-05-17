// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

/// Shared timing constants for AU parameter event scheduling.
public enum ParameterAutomationTiming {
    /// Duration of the primer event placed just before the first scheduled point.
    /// The primer starts this many seconds in the past so the parameter reaches its
    /// initial value before `AUEventSampleTimeImmediate` processing begins.
    public static let primerRampDuration: Float = 0.02

    /// Duration assigned to recorded automation points — short enough to be inaudible
    /// as a ramp but non-zero to avoid hard discontinuities in the parameter stream.
    public static let recordedPointRampDuration: Float = 0.01
}
