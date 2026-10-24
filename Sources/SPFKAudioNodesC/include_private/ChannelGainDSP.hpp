// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#pragma once

#include "DSPBase.h"
#include "DSPBase.hpp"
#include "ChannelGainDSP.h"
#include "ParameterRamper.h"

struct ChannelGainDSP : DSPBase {
  private:
    ParameterRamper leftGainRamp{1.0};
    ParameterRamper rightGainRamp{1.0};

    /// A packed ChannelGainOperationState: written from any thread, read once per `process`.
    std::atomic<uint64_t> operationState;

    static uint64_t pack(ChannelGainOperationState state);
    static ChannelGainOperationState unpack(uint64_t bits);

    void setOperationParameter(AUParameterAddress address, AUValue value);

    static bool isOperationParameter(AUParameterAddress address) {
        return address >= ChannelGainParameterFlipStereo && address <= ChannelGainParameterMidSideEncode;
    }

  public:
    ChannelGainDSP();

    void setOperationState(ChannelGainOperationState state) { operationState.store(pack(state)); }

    void setParameter(AUParameterAddress address, AUValue value, bool immediate) override;
    float getParameter(AUParameterAddress address) override;
    void startRamp(const AUParameterEvent &event) override;
    void process(FrameRange range) override;
};
