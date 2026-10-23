// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-audio-nodes Heavily based on the AudioKit version. All Rights Reserved.
// Revision History at http://github.com/AudioKit/AudioKit/

#include "FaderDSP.h"
#include "DSPBase.h"
#include "DSPBase.hpp"
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

    void setChannelParameter(AUParameterAddress address, AUValue value) {
        switch (address) {
        case FaderParameterFlipStereo:
            flipStereo = value > 0.5f;
            break;

        case FaderParameterMixToMono:
            mixToMono = value > 0.5f;
            break;

        case FaderParameterMonoSource:
            monoSource = (int)roundf(value);
            break;

        case FaderParameterMidSideDecode:
            midSideDecode = value > 0.5f;
            break;

        case FaderParameterMidSideWidth:
            midSideWidth = value;
            break;

        case FaderParameterMidSideEncode:
            midSideEncode = value > 0.5f;
            break;
        }
    }

    static bool isChannelParameter(AUParameterAddress address) {
        return address >= FaderParameterFlipStereo && address <= FaderParameterMidSideEncode;
    }

  public:
    FaderDSP() : DSPBase(1, true) {
        parameters[FaderParameterLeftGain] = &leftGainRamp;
        parameters[FaderParameterRightGain] = &rightGainRamp;
    }

    // Uses the ParameterAddress as a key
    void setParameter(AUParameterAddress address, AUValue value, bool immediate) override {
        if (isChannelParameter(address)) {
            setChannelParameter(address, value);
        } else {
            DSPBase::setParameter(address, value, immediate);
        }
    }

    // Uses the ParameterAddress as a key
    float getParameter(AUParameterAddress address) override {
        switch (address) {
        case FaderParameterFlipStereo:
            return flipStereo ? 1.f : 0.f;

        case FaderParameterMixToMono:
            return mixToMono ? 1.f : 0.f;

        case FaderParameterMonoSource:
            return (float)monoSource;

        case FaderParameterMidSideDecode:
            return midSideDecode ? 1.f : 0.f;

        case FaderParameterMidSideWidth:
            return midSideWidth;

        case FaderParameterMidSideEncode:
            return midSideEncode ? 1.f : 0.f;

        default:
            return DSPBase::getParameter(address);
        }
    }

    void startRamp(const AUParameterEvent &event) override {
        if (isChannelParameter(event.parameterAddress)) {
            setChannelParameter(event.parameterAddress, event.value);
        } else {
            DSPBase::startRamp(event);
        }
    }

    void process(FrameRange range) override {
        for (auto i : range) {
            float leftIn = inputSample(0, i);
            float rightIn = inputSample(1, i);

            float &leftOut = outputSample(0, i);
            float &rightOut = outputSample(1, i);

            float leftGain = leftGainRamp.getAndStep();
            float rightGain = rightGainRamp.getAndStep();

            // Channel operations act before gain, with the formulas of ChannelOperation (SPFKAudioBase).
            if (mixToMono) {
                float mono;
                switch (monoSource) {
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
            } else if (midSideDecode) {
                float side = midSideWidth * rightIn;
                float mid = leftIn;
                leftIn = mid + side;
                rightIn = mid - side;
            } else if (midSideEncode) {
                float mid = (leftIn + rightIn) * 0.5f;
                float side = (leftIn - rightIn) * 0.5f;
                leftIn = mid;
                rightIn = side;
            } else if (flipStereo) {
                std::swap(leftIn, rightIn);
            }

            leftOut = leftIn * leftGain;
            rightOut = rightIn * rightGain;
        }
    }
};

AK_REGISTER_DSP(FaderDSP, [kAudioUnitFaderSubTypeString cStringUsingEncoding:NSUTF8StringEncoding])
AK_REGISTER_PARAMETER(FaderParameterLeftGain)
AK_REGISTER_PARAMETER(FaderParameterRightGain)
AK_REGISTER_PARAMETER(FaderParameterFlipStereo)
AK_REGISTER_PARAMETER(FaderParameterMixToMono)
AK_REGISTER_PARAMETER(FaderParameterMonoSource)
AK_REGISTER_PARAMETER(FaderParameterMidSideDecode)
AK_REGISTER_PARAMETER(FaderParameterMidSideWidth)
AK_REGISTER_PARAMETER(FaderParameterMidSideEncode)
