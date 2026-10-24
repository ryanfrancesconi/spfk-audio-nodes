// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-audio-nodes

#import "DSPBase.h"
#include "ChannelGainDSP.hpp"
#include "TimePitchDSP.hpp"

/// Returns nullptr for a subtype with no DSP.
DSPRef createDSP(OSType code) {
    switch (code) {
    case kSPFKSubTypeChannelGain:
        return new ChannelGainDSP();

    case kSPFKSubTypeTimePitch:
        return new TimePitchDSP();

    default:
        return nullptr;
    }
}
