// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-audio-nodes

#import "DSPBase.h"
#include "ChannelGainDSP.hpp"

/// Returns nullptr for a subtype with no DSP.
DSPRef createDSP(OSType code) {
    switch (code) {
    case kSPFKSubTypeChannelGain:
        return new ChannelGainDSP();

    default:
        return nullptr;
    }
}
