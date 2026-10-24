// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import Foundation
import os
import SPFKAudioBase
import SPFKBase

/// Records a parameter's writes, touch and release included, in the order AudioToolbox delivers
/// them and with its host times, and merges them into a ``ParameterCurve``.
///
/// Call from one thread only. Events arrive on an AudioToolbox thread and are only appended there.
public final class AutomationRecorder {
    public struct Event: Equatable, Sendable {
        public var value: AUValue
        public var hostTime: UInt64
        public var eventType: AUParameterAutomationEventType
    }

    public enum MergeError: Error, Equatable {
        case nothingRecorded
        /// A recorded host time has no source position: nothing was running, or offline.
        case unmapped
        /// The positions do not run one way, as across a loop wrap.
        case notMonotonic
    }

    private let parameter: AUParameter
    private let events = OSAllocatedUnfairLock(initialState: [Event]())
    private var token: AUParameterObserverToken?

    public var recorded: [Event] { events.withLock { $0 } }
    public var isRecording: Bool { token != nil }

    public init(_ parameter: NodeParameter) throws {
        guard let auParameter = parameter.parameter else {
            throw NSError(description: "\(parameter.def.identifier) is not associated with a node")
        }
        self.parameter = auParameter
    }

    deinit {
        stop()
    }

    /// Starts a new recording, replacing any in progress.
    public func start() {
        stop()
        events.withLock { $0.removeAll() }
        token = parameter.token(byAddingParameterAutomationObserver: Self.observer(events))
    }

    public func stop() {
        guard let token else { return }
        parameter.removeParameterObserver(token)
        self.token = nil
    }

    // Built outside any actor: AudioToolbox calls it on its own thread.
    private nonisolated static func observer(_ events: OSAllocatedUnfairLock<[Event]>) -> AUParameterAutomationObserver {
        { count, pointer in
            let batch = (0 ..< count).map { Event(value: pointer[$0].value, hostTime: pointer[$0].hostTime, eventType: pointer[$0].eventType) }
            events.withLock { $0.append(contentsOf: batch) }
        }
    }

    // MARK: - Merge

    /// `curve` with the span the recording covers replaced by it, the recorded values joined by
    /// straight lines at the source positions `automation`'s running mapping gives their host times.
    public func merged(into curve: ParameterCurve, using automation: NodeAutomation) throws -> ParameterCurve {
        try merged(into: curve, position: automation.sourcePosition(atHostTime:))
    }

    func merged(into curve: ParameterCurve, position: (UInt64) -> Double?) throws -> ParameterCurve {
        let recorded = recorded
        guard !recorded.isEmpty else { throw MergeError.nothingRecorded }

        var points = try recorded.map { event -> (position: Double, value: AUValue) in
            guard let position = position(event.hostTime) else { throw MergeError.unmapped }
            return (position, event.value)
        }

        let forward = zip(points, points.dropFirst()).allSatisfy { $0.position <= $1.position }
        let backward = zip(points, points.dropFirst()).allSatisfy { $0.position >= $1.position }
        guard forward || backward else { throw MergeError.notMonotonic }
        if !forward { points.reverse() }

        var segments = [CurveSegment(start: points[0].position, end: points[0].position, startValue: points[0].value, endValue: points[0].value)]
        for (from, to) in zip(points, points.dropFirst()) {
            segments.append(CurveSegment(start: from.position, end: to.position, startValue: from.value, endValue: to.value))
        }

        return try curve.replacing(range: points[0].position ..< points[points.count - 1].position, with: segments)
    }
}
