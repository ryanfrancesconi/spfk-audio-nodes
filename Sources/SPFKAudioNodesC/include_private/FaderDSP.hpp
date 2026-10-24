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

    /// A packed FaderChannelState: written from any thread, read once per `process`.
    std::atomic<uint64_t> channelState;

    static uint64_t pack(FaderChannelState state);
    static FaderChannelState unpack(uint64_t bits);

    void setChannelParameter(AUParameterAddress address, AUValue value);

    static bool isChannelParameter(AUParameterAddress address) {
        return address >= FaderParameterFlipStereo && address <= FaderParameterMidSideEncode;
    }

  public:
    FaderDSP();

    void setChannelState(FaderChannelState state) { channelState.store(pack(state)); }

    void setParameter(AUParameterAddress address, AUValue value, bool immediate) override;
    float getParameter(AUParameterAddress address) override;
    void startRamp(const AUParameterEvent &event) override;
    void process(FrameRange range) override;
};
