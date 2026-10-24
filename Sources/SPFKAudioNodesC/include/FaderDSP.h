// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-audio-nodes Heavily based on the AudioKit version. All Rights Reserved.
// Revision History at http://github.com/AudioKit/AudioKit/

#ifndef FaderDSP_h
#define FaderDSP_h

#import "DSPBase.h"
#import <AudioToolbox/AUParameters.h>
#import <Foundation/Foundation.h>

// visible to swift

/// The Fader's `componentSubType`, which `createDSP` keys its DSP on.
static const OSType kSPFKSubTypeFader = 'fder';

typedef NS_CLOSED_ENUM(AUParameterAddress, FaderParameter) {
    FaderParameterLeftGain,
    FaderParameterRightGain,
    FaderParameterFlipStereo,
    FaderParameterMixToMono,
    FaderParameterMonoSource,
    FaderParameterMidSideDecode,
    FaderParameterMidSideWidth,
    FaderParameterMidSideEncode
};

/// Every channel parameter at once, so a render never sees half an operation.
typedef struct {
    bool flipStereo;
    bool mixToMono;
    uint8_t monoSource; // 0 average, 1 left, 2 right
    bool midSideDecode;
    bool midSideEncode;
    float midSideWidth;
} FaderChannelState;

CF_EXTERN_C_BEGIN

void setChannelStateFaderDSP(DSPRef pDSP, FaderChannelState state);

CF_EXTERN_C_END

#endif // !FaderDSP_h
