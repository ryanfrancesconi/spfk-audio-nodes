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

        var startTime = startTime ?? lastRenderTime

        // This is only for realtime automation - not rendering
        if !engine.isInManualRenderingMode,
           startTime.isHostTimeValid, !startTime.isSampleTimeValid
        {
            // Convert a hostTime based AVAudioTime to sampleTime which is needed for automation to work
            let startTimeSeconds = AVAudioTime.seconds(forHostTime: startTime.hostTime)
            let lastTimeSeconds = AVAudioTime.seconds(forHostTime: lastRenderTime.hostTime)
            let offsetSeconds = startTimeSeconds - lastTimeSeconds

            startTime = lastRenderTime.offset(seconds: offsetSeconds)
        }

        // this must be valid
        guard startTime.isSampleTimeValid else {
            throw NSError(description: "\(avAudioNode.debugDescription) startTime.isSampleTimeValid is false")
        }

        stopAutomation()

        let observer: AURenderObserver = try events.withUnsafeBufferPointer { automationPtr in
            guard let automationBaseAddress = automationPtr.baseAddress else {
                throw NSError(description: "Empty automation events buffer")
            }

            guard let observer = ParameterAutomationGetRenderObserver(
                parameter.address,
                avAudioNode.auAudioUnit.scheduleParameterBlock,
                Float(sampleRate),
                Float(startTime.sampleTime),
                automationBaseAddress,
                events.count
            ) else {
                throw NSError(description: "Failed to create render observer for \(avAudioNode.auAudioUnit.audioUnitName ?? "Audio Unit")")
            }

            return observer
        }

        renderObserverToken = avAudioNode.auAudioUnit.token(byAddingRenderObserver: observer)
    }

    /// Stop automation
    public func stopAutomation() {
        if let token = renderObserverToken {
            avAudioNode?.auAudioUnit.removeRenderObserver(token)
            renderObserverToken = nil
        }
    }

    /// Ramp from a source value
    ///
    /// - Parameters:
    ///   - start: initial value
    ///   - target: destination value
    ///   - duration: duration to ramp to the target value in seconds
    public func ramp(from start: AUValue, to target: AUValue, duration: Float) {
        let sampleRate = self.sampleRate
        ramp(to: start, duration: 0.02, delay: 0, sampleRate: sampleRate.float)
        ramp(to: target, duration: duration, delay: 0.02, sampleRate: sampleRate.float)
    }
}
