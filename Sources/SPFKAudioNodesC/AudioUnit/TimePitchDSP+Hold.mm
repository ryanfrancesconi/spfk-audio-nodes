// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#include "TimePitchDSP.hpp"
#include <cmath>

double holdStartUntilSampleTimeTimePitchDSP(DSPRef pDSP, double sampleTime) {
    return static_cast<TimePitchDSP *>(pDSP)->holdStartUntilSampleTime(sampleTime);
}

void holdStartUntilHostTimeTimePitchDSP(DSPRef pDSP, uint64_t hostTime) {
    static_cast<TimePitchDSP *>(pDSP)->holdStartUntilHostTime(hostTime);
}

void TimePitchDSP::hold(HoldKind kind, double sampleTime, uint64_t hostTime) {
    holdSequence.fetch_add(1, std::memory_order_acq_rel);
    holdKind.store(kind, std::memory_order_relaxed);
    holdSampleTime.store(sampleTime, std::memory_order_relaxed);
    holdHostTime.store(hostTime, std::memory_order_relaxed);
    holdSequence.fetch_add(1, std::memory_order_release);
}

// Held frames are pulled 1:1, so the upstream runs on from the last block in step with the output.
double TimePitchDSP::holdStartUntilSampleTime(double sampleTime) {
    const double outputTime = publishedOutputTime.load(std::memory_order_acquire);
    const double start = std::max(std::round(sampleTime), outputTime);
    hold(HoldSample, start, 0);
    return publishedInputTime.load(std::memory_order_relaxed) + (start - outputTime);
}

void TimePitchDSP::holdStartUntilHostTime(uint64_t hostTime) { hold(HoldHost, 0, hostTime); }

std::optional<AUAudioFrameCount> TimePitchDSP::framesHeld(const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount) {
    const uint64_t sequence = holdSequence.load(std::memory_order_acquire);
    if (sequence == releasedHold) return std::nullopt;
    if (sequence & 1) return frameCount;

    const int kind = holdKind.load(std::memory_order_relaxed);
    double start = holdSampleTime.load(std::memory_order_relaxed);
    const uint64_t hostTime = holdHostTime.load(std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_acquire);
    if (holdSequence.load(std::memory_order_relaxed) != sequence) return frameCount;

    if (kind == HoldHost) {
        if (!(timestamp->mFlags & kAudioTimeStampHostTimeValid)) return frameCount;
        start = timestamp->mSampleTime + (double(hostTime) - double(timestamp->mHostTime)) / hostTicksPerSecond * sampleRate;
    }

    const double into = std::max(0.0, std::round(start - timestamp->mSampleTime));
    if (into >= frameCount) return frameCount;

    releasedHold = sequence;
    return AUAudioFrameCount(into);
}
