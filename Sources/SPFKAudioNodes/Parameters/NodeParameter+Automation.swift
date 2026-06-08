// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes
// Heavily based on the AudioKit version. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

import AVFoundation
import SPFKAudioNodesC
import SPFKBase

extension NodeParameter {
    /// the `lastRenderTime` of the avAudioNode or a zero sampleTime AVAudioTime
    private var lastRenderTime: AVAudioTime {
        var value = avAudioNode?.lastRenderTime ?? AVAudioTime(sampleTime: 0, atRate: sampleRate)

        if !value.isSampleTimeValid {
            // if we're rendering, take the sample time from the engine
            if let engine = avAudioNode?.engine, engine.isInManualRenderingMode {
                value = AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: sampleRate)
            } else {
                // otherwise, a zero sampleTime
                value = AVAudioTime(sampleTime: 0, atRate: sampleRate)
            }
        }

        return value
    }

    /// Send an automation list to the parameter with an optional offset into the list's timeline.
    ///
    /// The offset in seconds is convenient if you have a set of fixed points but are playing
    /// from somewhere in the middle of them.
    /// - Parameters:
    ///   - events: An array of events
    ///   - offset: A time offset into the events
    public func automate(events: [AutomationEvent], offset: TimeInterval) throws {
        var startTime = lastRenderTime

        if offset != 0 {
            startTime = startTime.offset(seconds: -offset)
        }

        try automate(events: events, startTime: startTime)
    }

    /// Begin automation of the parameter.
    ///
    /// If `startTime` is nil, the automation will be scheduled as soon as possible.
    ///
    /// - Parameter events: automation curve
    /// - Parameter startTime: optional time to start automation
    public func automate(events: [AutomationEvent], startTime: AVAudioTime? = nil) throws {
        stopAutomation()
        let observer = try makeRenderObserver(events: events, startTime: startTime ?? lastRenderTime)
        guard let avAudioNode else { return }
        renderObserverToken = avAudioNode.auAudioUnit.token(byAddingRenderObserver: observer)
    }

    /// Stop automation
    public func stopAutomation() {
        if let token = renderObserverToken {
            avAudioNode?.auAudioUnit.removeRenderObserver(token)
            renderObserverToken = nil
        }
    }

    /// Register a loop-batch automation observer WITHOUT removing any existing observers.
    /// The token is appended to `loopObserverTokens` for later bulk removal via `stopLoopAutomation()`.
    ///
    /// Implements a sliding window of 2 active tokens: when a third batch observer is added, the
    /// oldest token is removed. By that point its audio has fully played (the prefill fires on the
    /// second-to-last segment, so the prior batch has one segment remaining when the next is queued
    /// and is fully expired by the time the third arrives). This bounds `loopObserverTokens` to at
    /// most 2 entries regardless of session length.
    public func addLoopObserver(events: [AutomationEvent], startTime: AVAudioTime) throws {
        // Sliding window: evict the oldest expired observer when a third batch is scheduled.
        if loopObserverTokens.count >= 2 {
            let expiredToken = loopObserverTokens.removeFirst()
            avAudioNode?.auAudioUnit.removeRenderObserver(expiredToken)
        }

        let observer = try makeRenderObserver(events: events, startTime: startTime)
        guard let avAudioNode else { return }
        let token = avAudioNode.auAudioUnit.token(byAddingRenderObserver: observer)
        loopObserverTokens.append(token)
    }

    /// Remove all loop-batch automation observers accumulated via `addLoopObserver`.
    public func stopLoopAutomation() {
        for token in loopObserverTokens {
            avAudioNode?.auAudioUnit.removeRenderObserver(token)
        }
        loopObserverTokens = []
    }

    /// Ramp from a source value
    ///
    /// - Parameters:
    ///   - start: initial value
    ///   - target: destination value
    ///   - duration: duration to ramp to the target value in seconds
    public func ramp(from start: AUValue, to target: AUValue, duration: Float) {
        let sampleRate = self.sampleRate
        ramp(to: start, duration: ParameterAutomationTiming.primerRampDuration, delay: 0, sampleRate: sampleRate.float)
        ramp(to: target, duration: duration, delay: ParameterAutomationTiming.primerRampDuration, sampleRate: sampleRate.float)
    }

    // MARK: - Private

    /// Shared render observer factory used by both `automate` and `addLoopObserver`.
    /// Handles host-to-sample-time conversion for realtime (non-manual-rendering) engines
    /// and validates that the resolved startTime has a valid sample time before creating
    /// the C-level observer.
    private func makeRenderObserver(events: [AutomationEvent], startTime: AVAudioTime) throws -> AURenderObserver {
        guard let avAudioNode else {
            throw NSError(description: "Underlying AVAudioNode is nil")
        }

        guard let parameter else {
            throw NSError(description: "Parameter is not associated")
        }

        guard let engine = avAudioNode.engine else {
            throw NSError(description: "\(avAudioNode.debugDescription) engine is nil")
        }

        let lastRenderTime = self.lastRenderTime
        var startTime = startTime

        // Convert a hostTime-only AVAudioTime to sampleTime, which is required for automation.
        if !engine.isInManualRenderingMode,
           startTime.isHostTimeValid, !startTime.isSampleTimeValid
        {
            let startTimeSeconds = AVAudioTime.seconds(forHostTime: startTime.hostTime)
            let lastTimeSeconds = AVAudioTime.seconds(forHostTime: lastRenderTime.hostTime)
            let offsetSeconds = startTimeSeconds - lastTimeSeconds
            startTime = lastRenderTime.offset(seconds: offsetSeconds)
        }

        guard startTime.isSampleTimeValid else {
            throw NSError(description: "\(avAudioNode.debugDescription) startTime.isSampleTimeValid is false")
        }

        return try events.withUnsafeBufferPointer { automationPtr in
            guard let automationBaseAddress = automationPtr.baseAddress else {
                throw NSError(description: "Empty automation events buffer")
            }

            guard let observer = ParameterAutomationGetRenderObserver(
                parameter.address,
                avAudioNode.auAudioUnit.scheduleParameterBlock,
                sampleRate,
                Double(startTime.sampleTime),
                automationBaseAddress,
                events.count
            ) else {
                throw NSError(description: "Failed to create render observer for \(avAudioNode.auAudioUnit.audioUnitName ?? "Audio Unit")")
            }

            return observer
        }
    }
}
