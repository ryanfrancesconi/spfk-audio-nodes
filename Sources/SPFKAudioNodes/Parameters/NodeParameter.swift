// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAudioBase
import SPFKBase

/// Wraps an AUParameter with clamped value access and the touch gesture; a node's automation is
/// its ``NodeAutomation``.
public class NodeParameter {
    public private(set) weak var avAudioNode: AVAudioNode?

    /// AU Parameter that this wraps
    public private(set) var parameter: AUParameter?

    // MARK: Parameter properties

    /// Value of the parameter
    public var value: AUValue {
        get { parameter?.value ?? def.defaultValue }
        set {
            parameter?.value = newValue.clamped(to: range)
        }
    }

    /// Boolean values for parameters
    public var boolValue: Bool {
        get { value > 0.5 }
        set { value = newValue ? 1.0 : 0.0 }
    }

    /// Minimum value
    public var minValue: AUValue {
        parameter?.minValue ?? def.range.lowerBound
    }

    /// Maximum value
    public var maxValue: AUValue {
        parameter?.maxValue ?? def.range.upperBound
    }

    /// Value range
    public var range: ClosedRange<AUValue> {
        if let parameter {
            return parameter.minValue ... parameter.maxValue
        }
        return def.range
    }

    public var sampleRate: Double {
        avAudioNode?.outputFormat(forBus: 0).sampleRate ??
            AudioDefaults.shared.unsafeSystemFormat.sampleRate
    }

    public var def: NodeParameterDef

    /// Init with definition
    /// - Parameter def: Node parameter definition
    public init(_ def: NodeParameterDef) {
        self.def = def
    }

    // MARK: Lifecycle

    /// Helper function to attach the parameter to the appropriate tree
    /// - Parameters:
    ///   - avAudioNode: AVAudioUnit to associate with
    public func associate(with avAudioNode: AVAudioNode) throws {
        self.avAudioNode = avAudioNode

        guard let tree = avAudioNode.auAudioUnit.parameterTree else {
            throw NSError(description: "No parameter tree found for \(avAudioNode).")
        }

        parameter = tree.parameter(withAddress: def.address)

        guard parameter != nil else {
            throw NSError(description: "Failed to find parameter at address \(def.address)")
        }
    }

    /// Helper function to attach the parameter to the appropriate tree
    /// - Parameters:
    ///   - avAudioNode: AVAudioUnit to associate with
    ///   - parameter: Parameter to associate
    public func associate(with avAudioNode: AVAudioNode, parameter: AUParameter) {
        self.avAudioNode = avAudioNode
        self.parameter = parameter
    }

    // MARK: Touch

    /// Begins a touch: an ``AutomationRecorder`` records it, and a `.touch` or `.latch` curve yields
    /// the parameter to it. Starts at `value`, or the current value.
    public func beginTouch(value: AUValue? = nil) {
        guard let value = value ?? parameter?.value else { return }
        parameter?.setValue(value, originator: nil, atHostTime: 0, eventType: .touch)
        (avAudioNode?.auAudioUnit as? SPFKAudioUnit)?.setTouched(def.address, true)
    }

    /// Ends a touch at `value`, or the current value; a `.touch` curve glides back from it.
    public func endTouch(value: AUValue? = nil) {
        guard let value = value ?? parameter?.value else { return }
        parameter?.setValue(value, originator: nil, atHostTime: 0, eventType: .release)
        (avAudioNode?.auAudioUnit as? SPFKAudioUnit)?.setTouched(def.address, false)
    }
}
