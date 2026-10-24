// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#include "TimePitchDSP.hpp"
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mach/mach_time.h>

void setQualityTimePitchDSP(DSPRef pDSP, TimePitchDSPQuality quality) {
    static_cast<TimePitchDSP *>(pDSP)->setQuality(quality);
}

double latencyAtRateTimePitchDSP(DSPRef pDSP, double rate) {
    return static_cast<TimePitchDSP *>(pDSP)->latencyAtRate(rate);
}

double holdUntilSampleTimeTimePitchDSP(DSPRef pDSP, double sampleTime) {
    return static_cast<TimePitchDSP *>(pDSP)->holdUntilSampleTime(sampleTime);
}

double holdUntilHostTimeTimePitchDSP(DSPRef pDSP, uint64_t hostTime) {
    return static_cast<TimePitchDSP *>(pDSP)->holdUntilHostTime(hostTime);
}

int64_t inputFramesPulledTimePitchDSP(DSPRef pDSP) { return static_cast<TimePitchDSP *>(pDSP)->framesPulled(); }

TimePitchDSP::TimePitchDSP() : DSPBase(1, false) {
    for (auto &value : parameterValues) value.store(0);
    parameterValues[TimePitchParameterRate].store(1);

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    hostTicksPerSecond = 1e9 * double(timebase.denom) / double(timebase.numer);
}

// Never behind the counter, so no frame the node pulls before the hold lands reaches it.
double TimePitchDSP::reserveUpstreamTime(double atLeast) {
    const double reserved = std::round(std::max(atLeast, publishedInputTime.load(std::memory_order_acquire) + 1));
    holdUpstreamTime.store(reserved, std::memory_order_relaxed);
    return reserved;
}

double TimePitchDSP::holdUntilSampleTime(double sampleTime) {
    const double upstream = reserveUpstreamTime(publishedInputTime.load(std::memory_order_acquire) + sampleRate);
    holdSampleTime.store(sampleTime, std::memory_order_relaxed);
    holdKind.store(HoldSample, std::memory_order_release);
    return upstream;
}

double TimePitchDSP::holdUntilHostTime(uint64_t hostTime) {
    // Where the upstream's own host-to-sample pairing, taken from its last pull, puts `hostTime`.
    const double ticks = double(hostTime) - double(lastPullHostTime.load(std::memory_order_acquire));
    const double upstream = reserveUpstreamTime(lastPullSampleTime.load(std::memory_order_relaxed) +
                                                ticks / hostTicksPerSecond * sampleRate);
    holdHostTime.store(hostTime, std::memory_order_relaxed);
    holdKind.store(HoldHost, std::memory_order_release);
    return upstream;
}

TimePitchDSP::~TimePitchDSP() {
    freeKernels();
    std::free(pullBufferList);
}

// MARK: - Parameters

void TimePitchDSP::setParameter(AUParameterAddress address, AUValue value, bool immediate) {
    if (address >= parameterCount) return;
    parameterValues[address].store(value, std::memory_order_relaxed);
    parameterGeneration.fetch_add(1, std::memory_order_release);
}

float TimePitchDSP::getParameter(AUParameterAddress address) {
    return address < parameterCount ? parameterValues[address].load(std::memory_order_relaxed) : 0.f;
}

void TimePitchDSP::startRamp(const AUParameterEvent &event) { setParameter(event.parameterAddress, event.value, true); }

void TimePitchDSP::pushParameters(TimePitchKernelRef target) {
    auto value = [this](TimePitchParameter address) { return double(parameterValues[address].load(std::memory_order_relaxed)); };

    TimePitchKernelSetTargets(target, value(TimePitchParameterRate),
                              std::pow(2.0, value(TimePitchParameterPitchCents) / 1200.0));
    TimePitchKernelSetTimbre(target, value(TimePitchParameterTonalityLimit), value(TimePitchParameterFormantShift),
                             value(TimePitchParameterFormantCorrection) > 0.5, value(TimePitchParameterFormantBase));
}

// MARK: - Kernels

TimePitchKernelRef TimePitchDSP::makeKernel(TimePitchDSPQuality kernelQuality) {
    auto kernelRef = TimePitchKernelCreate(uint32_t(channelCount), sampleRate, maximumFrames,
                                           kernelQuality == TimePitchDSPQualityEfficient ? TimePitchKernelQualityEfficient
                                                                                         : TimePitchKernelQualityBest,
                                           /* live */ true);
    if (kernelRef) {
        pushParameters(kernelRef);
        // A new kernel would otherwise ramp from rate 1 to its first target.
        TimePitchKernelReset(kernelRef);
    }
    return kernelRef;
}

void TimePitchDSP::freeKernels() {
    for (auto *slot : {&kernel, &pendingKernel, &retiredKernel}) {
        if (auto kernelRef = slot->exchange(nullptr)) TimePitchKernelDestroy(kernelRef);
    }
}

void TimePitchDSP::setQuality(TimePitchDSPQuality newQuality) {
    quality.store(newQuality);
    if (!isInitialized || maximumFrames == 0) return;

    // Each post is consumed at most once, so draining here keeps the retired slot to one kernel.
    if (auto retired = retiredKernel.exchange(nullptr)) TimePitchKernelDestroy(retired);

    if (auto superseded = pendingKernel.exchange(makeKernel(newQuality))) TimePitchKernelDestroy(superseded);
}

double TimePitchDSP::latencyAtRate(double rate) {
    auto kernelRef = kernel.load(std::memory_order_acquire);
    return kernelRef ? TimePitchKernelLatencySeconds(kernelRef, rate) : 0;
}

double TimePitchDSP::latencySeconds() {
    if (isBypassed) return 0;
    return latencyAtRate(parameterValues[TimePitchParameterRate].load(std::memory_order_relaxed));
}

// MARK: - Resources

void TimePitchDSP::init(int channelCount, double sampleRate) { DSPBase::init(channelCount, sampleRate); }

void TimePitchDSP::setMaximumFramesToRender(AUAudioFrameCount frames) {
    maximumFrames = frames;
    inputCapacity = AUAudioFrameCount(std::ceil(frames * kTimePitchMaxRate)) + 1;

    inputStorage.assign(channelCount, std::vector<float>(inputCapacity));
    inputPointers.resize(channelCount);
    outputPointers.resize(channelCount);
    for (int c = 0; c < channelCount; ++c) inputPointers[c] = inputStorage[c].data();

    std::free(pullBufferList);
    pullBufferList = (AudioBufferList *)std::calloc(1, offsetof(AudioBufferList, mBuffers) +
                                                          sizeof(AudioBuffer) * std::max(channelCount, 1));
    pullBufferList->mNumberBuffers = UInt32(channelCount);

    freeKernels();
    kernel.store(makeKernel(quality.load()), std::memory_order_release);
    appliedGeneration = parameterGeneration.load();
    wasBypassed = isBypassed;
    hasInputTime = false;
}

void TimePitchDSP::deinit() {
    DSPBase::deinit();
    freeKernels();
    maximumFrames = 0;
}

void TimePitchDSP::reset() {
    if (auto kernelRef = kernel.load(std::memory_order_acquire)) TimePitchKernelReset(kernelRef);
}

// MARK: - Render

AUAudioUnitStatus TimePitchDSP::pull(const AudioTimeStamp *timestamp, AUAudioFrameCount frames,
                                     AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
    if (timestamp->mFlags & kAudioTimeStampHostTimeValid) {
        lastPullSampleTime.store(inputSampleTime, std::memory_order_relaxed);
        lastPullHostTime.store(timestamp->mHostTime, std::memory_order_release);
    }

    for (AUAudioFrameCount done = 0; done < frames;) {
        const AUAudioFrameCount count = std::min(maximumFrames, frames - done);

        // Each sub-pull gets its own input-domain sample time, so no upstream node sees a time twice.
        AudioTimeStamp subTimestamp = *timestamp;
        subTimestamp.mSampleTime = inputSampleTime;

        for (int c = 0; c < channelCount; ++c) {
            pullBufferList->mBuffers[c] = {1, UInt32(count * sizeof(float)), inputStorage[c].data() + done};
        }

        AudioUnitRenderActionFlags flags = 0;
        const AUAudioUnitStatus status = pullInputBlock(&flags, &subTimestamp, count, 0, pullBufferList);
        if (status != noErr) return status;

        // An upstream node may answer with its own buffer rather than filling ours.
        for (int c = 0; c < channelCount; ++c) {
            float *expected = inputStorage[c].data() + done;
            if (pullBufferList->mBuffers[c].mData != expected) {
                std::memcpy(expected, pullBufferList->mBuffers[c].mData, count * sizeof(float));
            }
        }

        done += count;
        inputSampleTime += count;
        inputFramesPulled.fetch_add(count, std::memory_order_relaxed);
    }
    publishedInputTime.store(inputSampleTime, std::memory_order_release);
    return noErr;
}

AUAudioUnitStatus TimePitchDSP::render(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                                       AUAudioFrameCount frameCount, AudioBufferList *outputData,
                                       const AURenderEvent *events,
                                       AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
    if (!pullInputBlock) return kAudioUnitErr_NoConnection;
    if (frameCount > maximumFrames) return kAudioUnitErr_TooManyFramesToProcess;
    if (outputData->mNumberBuffers != UInt32(channelCount)) return kAudioUnitErr_FormatNotSupported;

    applyEvents(events);

    if (auto next = pendingKernel.exchange(nullptr, std::memory_order_acquire)) {
        retiredKernel.store(kernel.exchange(next, std::memory_order_acq_rel), std::memory_order_release);
        appliedGeneration = 0;
    }

    TimePitchKernelRef kernelRef = kernel.load(std::memory_order_acquire);
    if (!kernelRef) return kAudioUnitErr_Uninitialized;

    const uint32_t generation = parameterGeneration.load(std::memory_order_acquire);
    if (generation != appliedGeneration) {
        appliedGeneration = generation;
        pushParameters(kernelRef);
    }

    const bool bypassed = isBypassed;
    if (bypassed != wasBypassed) {
        wasBypassed = bypassed;
        TimePitchKernelReset(kernelRef);
    }

    if (!hasInputTime) {
        inputSampleTime = timestamp->mSampleTime;
        hasInputTime = true;
    }

    // A held start: silence and no pull until the start frame, then the upstream from its first frame.
    AUAudioFrameCount offset = 0;
    if (const int kind = holdKind.load(std::memory_order_acquire); kind != HoldNone) {
        double start = holdSampleTime.load(std::memory_order_relaxed);
        if (kind == HoldHost) {
            if (!(timestamp->mFlags & kAudioTimeStampHostTimeValid)) return noErr;
            const double ticks = double(holdHostTime.load(std::memory_order_relaxed)) - double(timestamp->mHostTime);
            start = timestamp->mSampleTime + ticks / hostTicksPerSecond * sampleRate;
        }
        const double into = start - timestamp->mSampleTime;
        if (into >= frameCount) {
            for (int c = 0; c < channelCount; ++c) {
                AudioBuffer &buffer = outputData->mBuffers[c];
                buffer.mDataByteSize = UInt32(frameCount * sizeof(float));
                if (buffer.mData) std::memset(buffer.mData, 0, frameCount * sizeof(float));
            }
            return noErr;
        }
        offset = into > 0 ? AUAudioFrameCount(std::llround(into)) : 0;
        int expected = kind;
        holdKind.compare_exchange_strong(expected, HoldNone);
        TimePitchKernelReset(kernelRef);

        // The first pull lands on the upstream time the hold reserved, where the player was started.
        inputSampleTime = holdUpstreamTime.load(std::memory_order_relaxed);
        hasInputTime = true;
    }
    const AUAudioFrameCount renderFrames = frameCount - offset;

    const AUAudioFrameCount inputFrames = bypassed ? renderFrames : TimePitchKernelInputFramesNeeded(kernelRef, renderFrames);
    if (inputFrames > inputCapacity) return kAudioUnitErr_TooManyFramesToProcess;

    if (const AUAudioUnitStatus status = pull(timestamp, inputFrames, pullInputBlock); status != noErr) {
        return status;
    }

    for (int c = 0; c < channelCount; ++c) {
        AudioBuffer &buffer = outputData->mBuffers[c];
        buffer.mDataByteSize = UInt32(frameCount * sizeof(float));

        if (buffer.mData && offset > 0) std::memset(buffer.mData, 0, offset * sizeof(float));

        if (bypassed && buffer.mData == nullptr) {
            buffer.mData = inputStorage[c].data();
        } else if (bypassed) {
            std::memcpy((float *)buffer.mData + offset, inputStorage[c].data(), renderFrames * sizeof(float));
        }
        outputPointers[c] = buffer.mData ? (float *)buffer.mData + offset : nullptr;
    }

    if (bypassed) return noErr;

    // A null output buffer asks the unit for its own, which AVAudioEngine never does.
    for (auto pointer : outputPointers) {
        if (!pointer) return kAudioUnitErr_InvalidParameter;
    }

    TimePitchKernelProcess(kernelRef, inputPointers.data(), inputFrames, outputPointers.data(), renderFrames);
    return noErr;
}
