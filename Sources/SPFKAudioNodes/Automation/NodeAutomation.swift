// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase

/// How a curve combines with the parameter's own value.
public enum AutomationCombine: Sendable {
    /// The parameter's value times the curve, so a write to the parameter never fights the curve.
    case multiply

    /// The curve's value.
    case replace
}

/// Who wins a replacing curve's parameter while ``NodeParameter/beginTouch(value:)`` holds it.
/// A multiplying curve ignores it, since a write never fights it.
public enum AutomationMode: Sendable {
    /// The curve, always.
    case read

    /// The parameter's own value while touched, gliding back to the curve over 20 ms on release.
    case touch

    /// The parameter's own value from the first touch until the next publish.
    case latch
}

/// A node's automation: every automated parameter, evaluated per frame on the render thread.
///
/// Each publish replaces the node's whole automation, so two curves on one parameter cannot
/// coexist. Call from one thread only, the one that owns the node.
public final class NodeAutomation {
    private let unit: SPFKAudioUnit

    /// The curves last published, empty once stopped.
    public private(set) var curves: [AUParameterAddress: ParameterCurve] = [:]

    public private(set) var mapping: TimelineMapping?

    public var isActive: Bool { !curves.isEmpty }

    public init(_ avAudioNode: AVAudioNode) throws {
        guard let unit = avAudioNode.auAudioUnit as? SPFKAudioUnit else {
            throw NSError(description: "\(avAudioNode) has no automation scheduler")
        }

        self.unit = unit
    }

    /// Replaces the node's automation with `curves` against `mapping`.
    ///
    /// A parameter already automated glides from its running value to the new curve over 20 ms, so
    /// an edit while playing cannot click. Pass `glides: false` for a new start — a play or a seek —
    /// which should open on its curve: a stop and a play published before one block render as a
    /// replacement, not as a stop.
    public func publish(
        _ curves: [AUParameterAddress: ParameterCurve],
        mapping: TimelineMapping,
        combine: AutomationCombine = .replace,
        mode: AutomationMode = .read,
        glides: Bool = true
    ) {
        guard !curves.isEmpty else { return stop() }

        unit.publishAutomation(curves, mapping: mapping, combine: combine, mode: mode, glides: glides)
        self.curves = curves
        self.mapping = mapping
    }

    /// Ends all automation; each parameter returns to its own value over 20 ms.
    public func stop() {
        unit.stopAutomation()
        curves = [:]
        mapping = nil
    }

    /// The value `address` rendered on the last frame of the last block, automation included.
    public func renderedValue(of address: AUParameterAddress) -> AUValue {
        unit.renderedValue(of: address)
    }

    // MARK: - Host time

    /// The render sample `hostTime` falls on, from the last block's timestamp; nil before a block
    /// has rendered, or offline, where there is no host clock.
    public func renderSample(atHostTime hostTime: UInt64) -> Int64? {
        let clock = unit.renderClock()
        guard clock.valid else { return nil }

        let ticks = hostTime >= clock.hostTime ? Double(hostTime - clock.hostTime) : -Double(clock.hostTime - hostTime)
        let frames = ticks * Self.secondsPerHostTick * clock.sampleRate / clock.rateScalar
        return clock.sampleTime + Int64(frames.rounded())
    }

    /// The length of the last rendered block in seconds, which in real time is the device's I/O
    /// buffer; nil before a block has rendered.
    public var renderBlockDuration: TimeInterval? {
        let clock = unit.renderClock()
        guard clock.frameCount > 0, clock.sampleRate > 0 else { return nil }
        return Double(clock.frameCount) / clock.sampleRate
    }

    /// How far ahead of the host clock the node renders, in seconds — a block's host time minus the
    /// time it rendered, the largest of the last eight blocks; nil before a block has rendered.
    public var renderAheadDuration: TimeInterval? {
        let clock = unit.renderClock()
        guard clock.valid else { return nil }
        return Double(clock.renderAheadTicks) * Self.secondsPerHostTick
    }

    /// The source position the running automation's mapping gives `hostTime`, nil when nothing runs.
    public func sourcePosition(atHostTime hostTime: UInt64) -> Double? {
        let clock = unit.renderClock()
        guard let mapping, clock.hasAnchor, let sample = renderSample(atHostTime: hostTime) else { return nil }

        return mapping.position(atRenderSample: sample, anchorSample: clock.anchorSample) { renderSample(atHostTime: $0) }
    }

    private static let secondsPerHostTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) * 1e-9
    }()

    // MARK: - Ramps

    /// Ramps `parameters` from where they rendered last to `target`, starting `delay` seconds after
    /// the next block. The parameters' own values are set to `target`, so the move persists.
    public func ramp(
        _ parameters: [AUParameterAddress],
        to target: AUValue,
        duration: TimeInterval,
        delay: TimeInterval = 0
    ) throws {
        try ramp(parameters, delay: delay, duration: duration, target: target) { [unit] address in
            unit.renderedValue(of: address)
        }
    }

    /// Ramps `parameters` from `start` to `target` over `duration`, from the next block.
    public func ramp(
        _ parameters: [AUParameterAddress],
        from start: AUValue,
        to target: AUValue,
        duration: TimeInterval
    ) throws {
        try ramp(parameters, delay: 0, duration: duration, target: target) { _ in start }
    }

    private func ramp(
        _ parameters: [AUParameterAddress],
        delay: TimeInterval,
        duration: TimeInterval,
        target: AUValue,
        start: (AUParameterAddress) -> AUValue
    ) throws {
        var curves: [AUParameterAddress: ParameterCurve] = [:]

        for address in parameters {
            let parameter = unit.parameterTree?.parameter(withAddress: address)
            let range = parameter.map { $0.minValue ... $0.maxValue }
            let clampedTarget = range.map { target.clamped(to: $0) } ?? target

            curves[address] = try ParameterCurve([
                CurveSegment(
                    start: delay, end: delay + max(0, duration), startValue: start(address), endValue: clampedTarget
                ),
            ])

            parameter?.value = clampedTarget
        }

        try publish(curves, mapping: TimelineMapping(renderAnchor: .atAdoption, sourceAnchor: 0, renderSampleRate: sampleRate))
    }

    private var sampleRate: Double {
        unit.outputBusses.count > 0 ? unit.outputBusses[0].format.sampleRate : AudioDefaults.shared.unsafeSystemFormat.sampleRate
    }
}
