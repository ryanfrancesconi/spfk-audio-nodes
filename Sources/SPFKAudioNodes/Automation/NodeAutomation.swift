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
    public func publish(
        _ curves: [AUParameterAddress: ParameterCurve],
        mapping: TimelineMapping,
        combine: AutomationCombine = .replace,
        mode: AutomationMode = .read
    ) {
        guard !curves.isEmpty else { return stop() }

        unit.publishAutomation(curves, mapping: mapping, combine: combine, mode: mode)
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
