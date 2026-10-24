// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-audio-nodes

#import "DSPBase.h"
#include "FaderDSP.hpp"

/// Returns nullptr for a subtype with no DSP.
DSPRef createDSP(OSType code) {
    switch (code) {
    case kSPFKSubTypeFader:
        return new FaderDSP();

    default:
        return nullptr;
    }
}
