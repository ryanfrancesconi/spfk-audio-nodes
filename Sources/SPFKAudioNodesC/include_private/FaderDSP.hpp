// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-audio-nodes Heavily based on the AudioKit version. All Rights Reserved.
// Revision History at http://github.com/AudioKit/AudioKit/

#pragma once

#include "DSPBase.h"
#include "DSPBase.hpp"
#include "FaderDSP.h"
#include "ParameterRamper.h"

struct FaderDSP : DSPBase {
  private:
    ParameterRamper leftGainRamp{1.0};
    ParameterRamper rightGainRamp{1.0};
    bool flipStereo = false;
    bool mixToMono = false;
    int monoSource = 0; // 0 average, 1 left, 2 right
    bool midSideDecode = false;
    float midSideWidth = 1.f;
    bool midSideEncode = false;

    void setChannelParameter(AUParameterAddress address, AUValue value);

    static bool isChannelParameter(AUParameterAddress address) {
        return address >= FaderParameterFlipStereo && address <= FaderParameterMidSideEncode;
    }

  public:
    FaderDSP();

    void setParameter(AUParameterAddress address, AUValue value, bool immediate) override;
    float getParameter(AUParameterAddress address) override;
    void startRamp(const AUParameterEvent &event) override;
    void process(FrameRange range) override;
};
