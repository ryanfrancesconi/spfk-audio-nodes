// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#import "DSPBase.h"
#include "DSPBase.hpp"
#import "ParameterRamper.h"

AUInternalRenderBlock internalRenderBlockDSP(DSPRef pDSP) { return pDSP->internalRenderBlock(); }

size_t inputBusCountDSP(DSPRef pDSP) { return pDSP->getInputBusCount(); }

bool canProcessInPlaceDSP(DSPRef pDSP) { return pDSP->bCanProcessInPlace; }

void setBufferDSP(DSPRef pDSP, AudioBufferList *buffer, size_t busIndex) { pDSP->setBuffer(buffer, busIndex); }

void allocateRenderResourcesDSP(DSPRef pDSP, uint32_t channelCount, double sampleRate, uint32_t maximumFrames) {
    pDSP->init(channelCount, sampleRate);
    pDSP->allocateAutomation(maximumFrames);
}

void deallocateRenderResourcesDSP(DSPRef pDSP) {
    pDSP->deinit();
    pDSP->automation.drainRetired();
}

void resetDSP(DSPRef pDSP) { pDSP->reset(); }

void setParameterValueDSP(DSPRef pDSP, AUParameterAddress address, AUValue value) {
    pDSP->setParameter(address, value, /* immediate */ false);
}

AUValue getParameterValueDSP(DSPRef pDSP, AUParameterAddress address) { return pDSP->getParameter(address); }

void setBypassDSP(DSPRef pDSP, bool bypass) { pDSP->isBypassed = bypass; }

bool getBypassDSP(DSPRef pDSP) { return pDSP->isBypassed; }

void deleteDSP(DSPRef pDSP) { delete pDSP; }

DSPBase::DSPBase(int inputBusCount, bool canProcessInPlace)
    : channelCount(2) // best guess
      ,
      sampleRate(48000) // best guess
      ,
      inputBufferLists(inputBusCount), bCanProcessInPlace(canProcessInPlace) {
    std::fill(parameters, parameters + maxParameters, nullptr);
}

void DSPBase::setBuffer(AudioBufferList *buffer, size_t busIndex) {
    if (internalBufferLists.size() <= busIndex) {
        internalBufferLists.resize(busIndex + 1);
    }

    internalBufferLists[busIndex] = buffer;
}

AUInternalRenderBlock DSPBase::internalRenderBlock() {
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount, NSInteger outputBusNumber, AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead,
                              AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
      if (pullInputBlock) {
          if (bCanProcessInPlace && inputBufferLists.size() == 1) {
              // pull input directly to output buffer
              inputBufferLists[0] = outputData;
              AudioUnitRenderActionFlags inputFlags = 0;
              AUAudioUnitStatus status = pullInputBlock(&inputFlags, timestamp, frameCount, 0, inputBufferLists[0]);

              if (status != noErr) {
                  return status;
              }
          } else {
              // pull input to internal buffer
              for (size_t i = 0; i < inputBufferLists.size(); i++) {
                  inputBufferLists[i] = internalBufferLists[i];

                  UInt32 byteSize = frameCount * sizeof(float);

                  for (UInt32 ch = 0; ch < inputBufferLists[i]->mNumberBuffers; ch++) {
                      inputBufferLists[i]->mBuffers[ch].mDataByteSize = byteSize;
                  }

                  AudioUnitRenderActionFlags inputFlags = 0;
                  AUAudioUnitStatus status = pullInputBlock(&inputFlags, timestamp, frameCount, i, inputBufferLists[i]);

                  if (status != noErr) {
                      return status;
                  }
              }
          }
      }

      outputBufferList = outputData;
      processWithEvents(timestamp, frameCount, realtimeEventListHead);

      return noErr;
    };
}

void DSPBase::setParameter(AUParameterAddress address, float value, bool immediate) {
    if (address < maxParameters) {
        if (auto parameter = parameters[address]) {
            if (immediate || !isInitialized) {
                parameter->startRamp(value, 0);
            } else {
                parameter->setUIValue(value);
            }
        }
    } else {
        return;
    }
}

float DSPBase::getParameter(AUParameterAddress address) {
    if (address < maxParameters) {
        if (auto parameter = parameters[address]) {
            return parameter->getUIValue();
        }
    } else {
        return 0.0f;
    }

    return 0.0f;
}

void DSPBase::init(int channelCount, double sampleRate) {
    this->channelCount = channelCount;
    this->sampleRate = sampleRate;
    isInitialized = true;
}

void DSPBase::deinit() { isInitialized = false; }

void DSPBase::allocateAutomation(AUAudioFrameCount maximumFrames) {
    // Rampers fill `parameters` from address 0 without gaps, as the dezipper loop assumes.
    int count = 0;
    while (count < maxParameters && parameters[count]) ++count;

    automation.allocate(count, maximumFrames, sampleRate, parameters);
}

DSPBase::~DSPBase() {}

void DSPBase::processWithEvents(AudioTimeStamp const *timestamp, AUAudioFrameCount frameCount,
                                AURenderEvent const *events) {
    now = timestamp->mSampleTime;

    // Chceck for parameter updates from the UI.
    for (int index = 0; index < maxParameters; ++index) {
        if (parameters[index]) {
            parameters[index]->dezipperCheck(sampleRate * 0.02f);
        } else {
            break;
        }
    }

    automation.beginBlock(timestamp, frameCount, parameters);

    AUAudioFrameCount framesRemaining = frameCount;
    AURenderEvent const *event = events;

    while (framesRemaining > 0) {
        // If there are no more events, we can process the entire remaining
        // segment and exit.
        if (event == nullptr) {
            AUAudioFrameCount const bufferOffset = frameCount - framesRemaining;
            processOrBypass(framesRemaining, bufferOffset);
            break;
        }

        // start late events late.
        auto timeZero = AUEventSampleTime(0);
        auto headEventTime = event->head.eventSampleTime;
        // Clamp to framesRemaining: events scheduled past the end of the current
        // buffer must not cause processOrBypass to read beyond the buffer or
        // framesRemaining to underflow (unsigned wrap → infinite loop).
        AUAudioFrameCount const framesThisSegment = AUAudioFrameCount(
            std::min((AUEventSampleTime)framesRemaining, std::max(timeZero, headEventTime - now)));

        // Compute everything before the next event.
        if (framesThisSegment > 0) {
            AUAudioFrameCount const bufferOffset = frameCount - framesRemaining;
            processOrBypass(framesThisSegment, bufferOffset);

            // Advance frames.
            framesRemaining -= framesThisSegment;
            // Advance time.
            now += framesThisSegment;
        }

        performAllSimultaneousEvents(now, event);
    }

    automation.endBlock(parameters);
}

void DSPBase::processOrBypass(AUAudioFrameCount frameCount, AUAudioFrameCount bufferOffset) {
    if (!isBypassed) {
        process(FrameRange{bufferOffset, frameCount});
    } else {
        // Advance all ramps.
        stepRampsBy(frameCount);

        // Copy input to output.
        if (inputBufferLists.size() and !bCanProcessInPlace) {
            for (int channel = 0; channel < channelCount; ++channel) {
                auto input = (const float *)inputBufferLists[0]->mBuffers[channel].mData + bufferOffset;
                auto output = (float *)outputBufferList->mBuffers[channel].mData + bufferOffset;
                std::copy(input, input + frameCount, output);
            }
        }

        // Generators should be silent.
        if (inputBufferLists.empty()) {
            zeroOutput(frameCount, bufferOffset);
        }
    }
}

/** From Apple Example code */
void DSPBase::performAllSimultaneousEvents(AUEventSampleTime now, AURenderEvent const *&event) {
    do {
        handleOneEvent(event);
        event = event->head.next;

        // While event is not null and is simultaneous (or late).
    } while (event && event->head.eventSampleTime <= now);
}

/** From Apple Example code */
void DSPBase::handleOneEvent(AURenderEvent const *event) {
    switch (event->head.eventType) {
    case AURenderEventParameter:
    case AURenderEventParameterRamp: {
        startRamp(event->parameter);
        break;
    }

    default:
        break;
    }
}

void DSPBase::startRamp(const AUParameterEvent &event) {
    auto address = event.parameterAddress;

    if (address < maxParameters) {
        auto ramper = parameters[address];

        if (ramper == nullptr) {
            return;
        }

        ramper->startRamp(event.value, event.rampDurationSampleFrames);
    } else {
        return;
    }
}

void DSPBase::stepRampsBy(AUAudioFrameCount frames) {
    for (int index = 0; index < maxParameters; ++index) {
        if (parameters[index]) {
            parameters[index]->stepBy(frames);
        }
    }
}

void DSPBase::zeroOutput(AUAudioFrameCount frames, AUAudioFrameCount bufferOffset) {
    for (int channel = 0; channel < channelCount; ++channel) {
        float *start = ((float *)outputBufferList->mBuffers[channel].mData) + bufferOffset;
        std::fill(start, start + frames, 0.0);
    }
}
