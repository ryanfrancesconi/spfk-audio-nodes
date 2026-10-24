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

/// Who wins a replacing curve's parameter while it is touched. Ignored when the curve multiplies.
typedef enum __attribute__((enum_extensibility(closed))) DSPAutomationMode : int32_t {
    /// The curve, always.
    DSPAutomationModeRead = 0,
    /// The parameter's own value while touched, gliding back to the curve on release.
    DSPAutomationModeTouch = 1,
    /// The parameter's own value from the first touch until the next publish.
    DSPAutomationModeLatch = 2,
} DSPAutomationMode;

/// One automated parameter. With `multiplies`, the rendered value is the parameter's own value
/// times the curve; otherwise the curve replaces it, as `mode` allows.
typedef struct DSPAutomationLane {
    AUParameterAddress address;
    bool multiplies;
    DSPAutomationMode mode;
    const SPFKCurveSegment *segments;
    long segmentCount;
} DSPAutomationLane;

/// The last rendered block's start on the render timeline and the host clock, and where the running
/// automation's mapping is anchored. `valid` is false before a block has rendered.
typedef struct DSPRenderClock {
    bool valid;
    int64_t sampleTime;
    uint64_t hostTime;
    double rateScalar;
    double sampleRate;
    bool hasAnchor;
    int64_t anchorSample;
} DSPRenderClock;

CF_EXTERN_C_BEGIN

/// Replaces the node's whole automation with `lanes` against `mapping`; no lanes stops it. Copies
/// everything it is given. Call from one thread only.
void publishAutomationDSP(DSPRef pDSP, const DSPAutomationLane *lanes, long laneCount, SPFKTimelineMapping mapping,
                          DSPAutomationAnchor anchor);

/// Frees snapshots the render thread has finished with. Call from the publishing thread.
void drainRetiredAutomationDSP(DSPRef pDSP);

/// The value the parameter rendered on the last frame of the last block.
AUValue renderedValueDSP(DSPRef pDSP, AUParameterAddress address);

/// The render clock as of the last block. From any thread.
DSPRenderClock renderClockDSP(DSPRef pDSP);

/// Whether the parameter is held by a touch gesture. From any thread.
void setParameterTouchedDSP(DSPRef pDSP, AUParameterAddress address, bool touched);

CF_EXTERN_C_END
