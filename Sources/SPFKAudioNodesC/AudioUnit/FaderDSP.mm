// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-audio-nodes Heavily based on the AudioKit version. All Rights Reserved.
// Revision History at http://github.com/AudioKit/AudioKit/

#include "FaderDSP.hpp"
#include <cstring>

void setChannelStateFaderDSP(DSPRef pDSP, FaderChannelState state) {
    static_cast<FaderDSP *>(pDSP)->setChannelState(state);
}

FaderDSP::FaderDSP() : DSPBase(1, true) {
    parameters[FaderParameterLeftGain] = &leftGainRamp;
    parameters[FaderParameterRightGain] = &rightGainRamp;
    channelState.store(pack(FaderChannelState{.midSideWidth = 1.f}));
}

// Bits 0-3 the flags, 8-15 the mono source, 32-63 the width's float bits.
uint64_t FaderDSP::pack(FaderChannelState state) {
    uint32_t width;
    std::memcpy(&width, &state.midSideWidth, sizeof(width));

    return uint64_t(state.flipStereo) | uint64_t(state.mixToMono) << 1 | uint64_t(state.midSideDecode) << 2 |
           uint64_t(state.midSideEncode) << 3 | uint64_t(state.monoSource) << 8 | uint64_t(width) << 32;
}

FaderChannelState FaderDSP::unpack(uint64_t bits) {
    FaderChannelState state;
    state.flipStereo = bits & 1;
    state.mixToMono = bits >> 1 & 1;
    state.midSideDecode = bits >> 2 & 1;
    state.midSideEncode = bits >> 3 & 1;
    state.monoSource = uint8_t(bits >> 8);

    uint32_t width = uint32_t(bits >> 32);
    std::memcpy(&state.midSideWidth, &width, sizeof(width));
    return state;
}

void FaderDSP::setChannelParameter(AUParameterAddress address, AUValue value) {
    uint64_t expected = channelState.load();
    uint64_t desired;

    do {
        FaderChannelState state = unpack(expected);

        switch (address) {
        case FaderParameterFlipStereo:
            state.flipStereo = value > 0.5f;
            break;

        case FaderParameterMixToMono:
            state.mixToMono = value > 0.5f;
            break;

        case FaderParameterMonoSource:
            state.monoSource = uint8_t(roundf(value));
            break;

        case FaderParameterMidSideDecode:
            state.midSideDecode = value > 0.5f;
            break;

        case FaderParameterMidSideWidth:
            state.midSideWidth = value;
            break;

        case FaderParameterMidSideEncode:
            state.midSideEncode = value > 0.5f;
            break;
        }

        desired = pack(state);
    } while (!channelState.compare_exchange_weak(expected, desired));
}

// Uses the ParameterAddress as a key
void FaderDSP::setParameter(AUParameterAddress address, AUValue value, bool immediate) {
    if (isChannelParameter(address)) {
        setChannelParameter(address, value);
    } else {
        DSPBase::setParameter(address, value, immediate);
    }
}

// Uses the ParameterAddress as a key
float FaderDSP::getParameter(AUParameterAddress address) {
    FaderChannelState state = unpack(channelState.load());

    switch (address) {
    case FaderParameterFlipStereo:
        return state.flipStereo ? 1.f : 0.f;

    case FaderParameterMixToMono:
        return state.mixToMono ? 1.f : 0.f;

    case FaderParameterMonoSource:
        return (float)state.monoSource;

    case FaderParameterMidSideDecode:
        return state.midSideDecode ? 1.f : 0.f;

    case FaderParameterMidSideWidth:
        return state.midSideWidth;

    case FaderParameterMidSideEncode:
        return state.midSideEncode ? 1.f : 0.f;

    default:
        return DSPBase::getParameter(address);
    }
}

void FaderDSP::startRamp(const AUParameterEvent &event) {
    if (isChannelParameter(event.parameterAddress)) {
        setChannelParameter(event.parameterAddress, event.value);
    } else {
        DSPBase::startRamp(event);
    }
}

void FaderDSP::process(FrameRange range) {
    const FaderChannelState channel = unpack(channelState.load(std::memory_order_relaxed));

    for (auto i : range) {
        float leftIn = inputSample(0, i);
        float rightIn = inputSample(1, i);

        float &leftOut = outputSample(0, i);
        float &rightOut = outputSample(1, i);

        float leftGain = leftGainRamp.getAndStep();
        float rightGain = rightGainRamp.getAndStep();

        // Channel operations act before gain, with the formulas of ChannelOperation (SPFKAudioBase).
        if (channel.mixToMono) {
            float mono;
            switch (channel.monoSource) {
            case 1:
                mono = leftIn;
                break;
            case 2:
                mono = rightIn;
                break;
            default:
                mono = (leftIn + rightIn) * 0.5f;
            }
            leftIn = rightIn = mono;
        } else if (channel.midSideDecode) {
            float side = channel.midSideWidth * rightIn;
            float mid = leftIn;
            leftIn = mid + side;
            rightIn = mid - side;
        } else if (channel.midSideEncode) {
            float mid = (leftIn + rightIn) * 0.5f;
            float side = (leftIn - rightIn) * 0.5f;
            leftIn = mid;
            rightIn = side;
        } else if (channel.flipStereo) {
            std::swap(leftIn, rightIn);
        }

        leftOut = leftIn * leftGain;
        rightOut = rightIn * rightGain;
    }
}
