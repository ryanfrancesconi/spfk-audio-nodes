// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AudioToolbox
import Foundation
import SPFKAudioBase
import SPFKAudioBaseC
import SPFKAudioNodesC

extension SPFKAudioUnit {
    /// Replaces this unit's whole automation with `curves` against `mapping`.
    func publishAutomation(
        _ curves: [AUParameterAddress: ParameterCurve],
        mapping: TimelineMapping,
        combine: AutomationCombine,
        mode: AutomationMode,
        glides: Bool
    ) {
        let entries = curves.sorted { $0.key < $1.key }
        var flat: [SPFKCurveSegment] = []
        var ranges: [(address: AUParameterAddress, offset: Int, count: Int)] = []

        for (address, curve) in entries {
            let segments = curve.renderSegments
            ranges.append((address, flat.count, segments.count))
            flat += segments
        }

        let anchor = mapping.renderAnchor.dspAnchor
        let anchorSample: Int64 = if case let .sample(sample) = mapping.renderAnchor { sample } else { 0 }
        let renderMapping = mapping.renderMapping(anchorSample: anchorSample)
        let changes = mapping.rateChanges.map { DSPRateChange(effectiveFrom: $0.effectiveFrom.dspAnchor, rate: $0.rate) }

        flat.withUnsafeBufferPointer { segments in
            let lanes = ranges.map { range in
                DSPAutomationLane(
                    address: range.address,
                    multiplies: combine == .multiply,
                    mode: mode.dspMode,
                    segments: segments.baseAddress.map { $0 + range.offset },
                    segmentCount: range.count
                )
            }

            lanes.withUnsafeBufferPointer { lanes in
                changes.withUnsafeBufferPointer { changes in
                    publishAutomationDSP(
                        dsp, lanes.baseAddress, lanes.count, renderMapping, anchor, changes.baseAddress, changes.count, glides
                    )
                }
            }
        }
    }

    /// Ends this unit's automation; each parameter returns to its own value over 20 ms.
    func stopAutomation() {
        let mapping = SPFKTimelineMapping(
            renderAnchor: 0, sourceAnchor: 0, rate: 1, direction: 1, loopStart: 0, loopEnd: 0, renderSampleRate: 1
        )
        let anchor = DSPAutomationAnchor(kind: .atAdoption, sampleTime: 0, hostTime: 0)
        publishAutomationDSP(dsp, nil, 0, mapping, anchor, nil, 0, true)
    }

    func renderClock() -> DSPRenderClock {
        renderClockDSP(dsp)
    }

    func setTouched(_ address: AUParameterAddress, _ touched: Bool) {
        setParameterTouchedDSP(dsp, address, touched)
    }

    /// The value `address` rendered on the last frame of the last block.
    func renderedValue(of address: AUParameterAddress) -> AUValue {
        renderedValueDSP(dsp, address)
    }
}

extension TimelineAnchor {
    var dspAnchor: DSPAutomationAnchor {
        switch self {
        case let .sample(sample): DSPAutomationAnchor(kind: .sample, sampleTime: sample, hostTime: 0)
        case let .host(hostTime): DSPAutomationAnchor(kind: .host, sampleTime: 0, hostTime: hostTime)
        case .atAdoption: DSPAutomationAnchor(kind: .atAdoption, sampleTime: 0, hostTime: 0)
        }
    }
}

extension AutomationMode {
    var dspMode: DSPAutomationMode {
        switch self {
        case .read: .read
        case .touch: .touch
        case .latch: .latch
        }
    }
}
