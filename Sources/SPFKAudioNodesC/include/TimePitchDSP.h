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

/// How long after a block applies a new rate the change is heard, modeled as one step: the output
/// latency plus half the rate ramp. 0 before render resources exist.
double rateChangeDelayTimePitchDSP(DSPRef pDSP);

/// Every input frame pulled since render resources were allocated, bypassed or not.
int64_t inputFramesPulledTimePitchDSP(DSPRef pDSP);

/// Holds the node's start until `sampleTime`, an output sample time. Until then it renders silence
/// and pulls its upstream 1:1, discarding it, so the upstream's timeline never jumps; from then it
/// renders from a reset. Returns the upstream sample time of the start frame, where a player
/// feeding the node is started. Exact only while nothing renders concurrently, as offline. A time
/// already past starts at the next block.
double holdStartUntilSampleTimeTimePitchDSP(DSPRef pDSP, double sampleTime);

/// As `holdStartUntilSampleTimeTimePitchDSP`, at a host time. A player feeding the node is started
/// at the same host time, after this call.
void holdStartUntilHostTimeTimePitchDSP(DSPRef pDSP, uint64_t hostTime);

CF_EXTERN_C_END

#endif // !TimePitchDSP_h
