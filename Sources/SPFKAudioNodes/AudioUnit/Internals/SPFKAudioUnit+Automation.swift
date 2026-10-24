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
        combine: AutomationCombine
    ) {
        let entries = curves.sorted { $0.key < $1.key }
        var flat: [SPFKCurveSegment] = []
        var ranges: [(address: AUParameterAddress, offset: Int, count: Int)] = []

        for (address, curve) in entries {
            let segments = curve.renderSegments
            ranges.append((address, flat.count, segments.count))
            flat += segments
        }

        let anchor: DSPAutomationAnchor
        let anchorSample: Int64

        switch mapping.renderAnchor {
        case let .sample(sample):
            anchor = DSPAutomationAnchor(kind: .sample, sampleTime: sample, hostTime: 0)
            anchorSample = sample
        case let .host(hostTime):
            anchor = DSPAutomationAnchor(kind: .host, sampleTime: 0, hostTime: hostTime)
            anchorSample = 0
        case .atAdoption:
            anchor = DSPAutomationAnchor(kind: .atAdoption, sampleTime: 0, hostTime: 0)
            anchorSample = 0
        }

        let renderMapping = mapping.renderMapping(anchorSample: anchorSample)

        flat.withUnsafeBufferPointer { segments in
            let lanes = ranges.map { range in
                DSPAutomationLane(
                    address: range.address,
                    multiplies: combine == .multiply,
                    segments: segments.baseAddress.map { $0 + range.offset },
                    segmentCount: range.count
                )
            }

            lanes.withUnsafeBufferPointer { lanes in
                publishAutomationDSP(dsp, lanes.baseAddress, lanes.count, renderMapping, anchor)
            }
        }
    }

    /// Ends this unit's automation; each parameter returns to its own value over 20 ms.
    func stopAutomation() {
        let mapping = SPFKTimelineMapping(
            renderAnchor: 0, sourceAnchor: 0, rate: 1, direction: 1, loopStart: 0, loopEnd: 0, renderSampleRate: 1
        )
        let anchor = DSPAutomationAnchor(kind: .atAdoption, sampleTime: 0, hostTime: 0)
        publishAutomationDSP(dsp, nil, 0, mapping, anchor)
    }

    /// The value `address` rendered on the last frame of the last block.
    func renderedValue(of address: AUParameterAddress) -> AUValue {
        renderedValueDSP(dsp, address)
    }
}
