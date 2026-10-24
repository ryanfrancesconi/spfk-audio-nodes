// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#ifndef TimePitchDSP_h
#define TimePitchDSP_h

#import "DSPBase.h"
#import <AudioToolbox/AUParameters.h>
#import <Foundation/Foundation.h>

// visible to swift

/// The TimePitch's `componentSubType`, which `createDSP` keys its DSP on. Not Apple's `'tmpt'`.
static const OSType kSPFKSubTypeTimePitch = 'tpch';

typedef NS_CLOSED_ENUM(AUParameterAddress, TimePitchParameter) {
    TimePitchParameterRate,
    TimePitchParameterPitchCents,
    TimePitchParameterTonalityLimit,
    TimePitchParameterFormantShift,
    TimePitchParameterFormantCorrection,
    TimePitchParameterFormantBase
};

typedef NS_CLOSED_ENUM(uint8_t, TimePitchDSPQuality) {
    TimePitchDSPQualityBest,
    TimePitchDSPQualityEfficient
};

CF_EXTERN_C_BEGIN

/// Builds a kernel at `quality` on the calling thread and hands it to the render thread, which
/// swaps it in at its next block. Frees any kernel an earlier swap retired.
void setQualityTimePitchDSP(DSPRef pDSP, TimePitchDSPQuality quality);

/// The live kernel's latency at a constant `rate`, in seconds; 0 before render resources exist.
double latencyAtRateTimePitchDSP(DSPRef pDSP, double rate);

/// Every input frame pulled since render resources were allocated, bypassed or not.
int64_t inputFramesPulledTimePitchDSP(DSPRef pDSP);

CF_EXTERN_C_END

#endif // !TimePitchDSP_h
