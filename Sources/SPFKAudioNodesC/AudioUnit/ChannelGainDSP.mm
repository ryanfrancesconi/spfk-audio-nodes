// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#include "ChannelGainDSP.hpp"
#include <cstring>

void setOperationStateChannelGainDSP(DSPRef pDSP, ChannelGainOperationState state) {
    static_cast<ChannelGainDSP *>(pDSP)->setOperationState(state);
}

ChannelGainDSP::ChannelGainDSP() : DSPBase(1, true) {
    parameters[ChannelGainParameterLeftGain] = &leftGainRamp;
    parameters[ChannelGainParameterRightGain] = &rightGainRamp;
    operationState.store(pack(ChannelGainOperationState{.midSideWidth = 1.f}));
}

// Bits 0-3 the flags, 8-15 the mono source, 32-63 the width's float bits.
uint64_t ChannelGainDSP::pack(ChannelGainOperationState state) {
    uint32_t width;
    std::memcpy(&width, &state.midSideWidth, sizeof(width));

    return uint64_t(state.flipStereo) | uint64_t(state.mixToMono) << 1 | uint64_t(state.midSideDecode) << 2 |
           uint64_t(state.midSideEncode) << 3 | uint64_t(state.monoSource) << 8 | uint64_t(width) << 32;
}

ChannelGainOperationState ChannelGainDSP::unpack(uint64_t bits) {
    ChannelGainOperationState state;
    state.flipStereo = bits & 1;
    state.mixToMono = bits >> 1 & 1;
    state.midSideDecode = bits >> 2 & 1;
    state.midSideEncode = bits >> 3 & 1;
    state.monoSource = uint8_t(bits >> 8);

    uint32_t width = uint32_t(bits >> 32);
    std::memcpy(&state.midSideWidth, &width, sizeof(width));
    return state;
}

void ChannelGainDSP::setOperationParameter(AUParameterAddress address, AUValue value) {
    uint64_t expected = operationState.load();
    uint64_t desired;

    do {
        ChannelGainOperationState state = unpack(expected);

        switch (address) {
        case ChannelGainParameterFlipStereo:
            state.flipStereo = value > 0.5f;
            break;

        case ChannelGainParameterMixToMono:
            state.mixToMono = value > 0.5f;
            break;

        case ChannelGainParameterMonoSource:
            state.monoSource = uint8_t(roundf(value));
            break;

        case ChannelGainParameterMidSideDecode:
            state.midSideDecode = value > 0.5f;
            break;

        case ChannelGainParameterMidSideWidth:
            state.midSideWidth = value;
            break;

        case ChannelGainParameterMidSideEncode:
            state.midSideEncode = value > 0.5f;
            break;
        }

        desired = pack(state);
    } while (!operationState.compare_exchange_weak(expected, desired));
}

// Uses the ParameterAddress as a key
void ChannelGainDSP::setParameter(AUParameterAddress address, AUValue value, bool immediate) {
    if (isOperationParameter(address)) {
        setOperationParameter(address, value);
    } else {
        DSPBase::setParameter(address, value, immediate);
    }
}

// Uses the ParameterAddress as a key
float ChannelGainDSP::getParameter(AUParameterAddress address) {
    ChannelGainOperationState state = unpack(operationState.load());

    switch (address) {
    case ChannelGainParameterFlipStereo:
        return state.flipStereo ? 1.f : 0.f;

    case ChannelGainParameterMixToMono:
        return state.mixToMono ? 1.f : 0.f;

    case ChannelGainParameterMonoSource:
        return (float)state.monoSource;

    case ChannelGainParameterMidSideDecode:
        return state.midSideDecode ? 1.f : 0.f;

    case ChannelGainParameterMidSideWidth:
        return state.midSideWidth;

    case ChannelGainParameterMidSideEncode:
        return state.midSideEncode ? 1.f : 0.f;

    default:
        return DSPBase::getParameter(address);
    }
}

void ChannelGainDSP::startRamp(const AUParameterEvent &event) {
    if (isOperationParameter(event.parameterAddress)) {
        setOperationParameter(event.parameterAddress, event.value);
    } else {
        DSPBase::startRamp(event);
    }
}

void ChannelGainDSP::process(FrameRange range) {
    const ChannelGainOperationState channel = unpack(operationState.load(std::memory_order_relaxed));

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
