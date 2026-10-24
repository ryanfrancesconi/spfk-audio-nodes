// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#pragma once

#import <AudioToolbox/AudioToolbox.h>

#include <SPFKCurve.h>

#import "DSPBase.h"

/* visible to swift */

/// How a published mapping's render anchor is found.
typedef enum __attribute__((enum_extensibility(closed))) DSPAutomationAnchorKind : int32_t {
    /// `sampleTime`, on the engine's render timeline.
    DSPAutomationAnchorSample = 0,
    /// `hostTime`, bound to a sample from the adopting block's timestamp.
    DSPAutomationAnchorHost = 1,
    /// The first frame of the adopting block.
    DSPAutomationAnchorAtAdoption = 2,
} DSPAutomationAnchorKind;

typedef struct DSPAutomationAnchor {
    DSPAutomationAnchorKind kind;
    int64_t sampleTime;
    uint64_t hostTime;
} DSPAutomationAnchor;

/// One automated parameter. With `multiplies`, the rendered value is the parameter's own value
/// times the curve; otherwise the curve replaces it.
typedef struct DSPAutomationLane {
    AUParameterAddress address;
    bool multiplies;
    const SPFKCurveSegment *segments;
    long segmentCount;
} DSPAutomationLane;

CF_EXTERN_C_BEGIN

/// Replaces the node's whole automation with `lanes` against `mapping`; no lanes stops it. Copies
/// everything it is given. Call from one thread only.
void publishAutomationDSP(DSPRef pDSP, const DSPAutomationLane *lanes, long laneCount, SPFKTimelineMapping mapping,
                          DSPAutomationAnchor anchor);

/// Frees snapshots the render thread has finished with. Call from the publishing thread.
void drainRetiredAutomationDSP(DSPRef pDSP);

/// The value the parameter rendered on the last frame of the last block.
AUValue renderedValueDSP(DSPRef pDSP, AUParameterAddress address);

CF_EXTERN_C_END
