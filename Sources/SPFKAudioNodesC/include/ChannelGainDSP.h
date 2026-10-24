// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#ifndef ChannelGainDSP_h
#define ChannelGainDSP_h

#import "DSPBase.h"
#import <AudioToolbox/AUParameters.h>
#import <Foundation/Foundation.h>

// visible to swift

/// The ChannelGain's `componentSubType`, which `createDSP` keys its DSP on.
static const OSType kSPFKSubTypeChannelGain = 'chgn';

typedef NS_CLOSED_ENUM(AUParameterAddress, ChannelGainParameter) {
    ChannelGainParameterLeftGain,
    ChannelGainParameterRightGain,
    ChannelGainParameterFlipStereo,
    ChannelGainParameterMixToMono,
    ChannelGainParameterMonoSource,
    ChannelGainParameterMidSideDecode,
    ChannelGainParameterMidSideWidth,
    ChannelGainParameterMidSideEncode
};

/// Every channel parameter at once, so a render never sees half an operation.
typedef struct {
    bool flipStereo;
    bool mixToMono;
    uint8_t monoSource; // 0 average, 1 left, 2 right
    bool midSideDecode;
    bool midSideEncode;
    float midSideWidth;
} ChannelGainOperationState;

CF_EXTERN_C_BEGIN

void setOperationStateChannelGainDSP(DSPRef pDSP, ChannelGainOperationState state);

CF_EXTERN_C_END

#endif // !ChannelGainDSP_h
