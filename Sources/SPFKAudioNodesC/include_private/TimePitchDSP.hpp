// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#pragma once

#include "DSPBase.h"
#include "DSPBase.hpp"
#include "SPFKTimePitchKernel.h"
#include "TimePitchDSP.h"
#include <optional>

/// Signalsmith Stretch as an insert: pulls `rate` × the frames it renders.
///
/// Every kernel setter runs on the render thread at a block boundary. Other threads only store
/// parameters and post kernels, and only the posting thread frees one.
struct TimePitchDSP : DSPBase {
  private:
    static constexpr int parameterCount = TimePitchParameterFormantBase + 1;

    std::atomic<float> parameterValues[parameterCount];
    std::atomic<uint32_t> parameterGeneration{1};
    std::atomic<TimePitchDSPQuality> quality{TimePitchDSPQualityBest};

    /// Owned by the render thread once swapped in.
    std::atomic<TimePitchKernelRef> kernel{nullptr};
    std::atomic<TimePitchKernelRef> pendingKernel{nullptr};
    std::atomic<TimePitchKernelRef> retiredKernel{nullptr};

    std::atomic<int64_t> inputFramesPulled{0};

    enum HoldKind : int { HoldSample, HoldHost };
    /// A seqlock: odd while a hold is written, and a hold is pending while it differs from `releasedHold`.
    std::atomic<uint64_t> holdSequence{0};
    std::atomic<int> holdKind{HoldSample};
    std::atomic<double> holdSampleTime{0};
    std::atomic<uint64_t> holdHostTime{0};
    /// The upstream and output sample times at the end of the last block.
    std::atomic<double> publishedInputTime{0};
    std::atomic<double> publishedOutputTime{0};
    double hostTicksPerSecond = 0;

    void hold(HoldKind kind, double sampleTime, uint64_t hostTime);

    /// The frames of this block before a pending start, or none without one; the start is
    /// released when it falls inside the block.
    std::optional<AUAudioFrameCount> framesHeld(const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount);

    AUAudioFrameCount maximumFrames = 0;
    AUAudioFrameCount inputCapacity = 0;
    std::vector<std::vector<float>> inputStorage;
    std::vector<const float *> inputPointers;
    std::vector<float *> outputPointers;
    AudioBufferList *pullBufferList = nullptr;

    // Render thread only.
    uint32_t appliedGeneration = 0;
    bool wasBypassed = false;
    bool hasInputTime = false;
    uint64_t releasedHold = 0;
    Float64 inputSampleTime = 0;

    TimePitchKernelRef makeKernel(TimePitchDSPQuality kernelQuality);
    void pushParameters(TimePitchKernelRef target);
    void freeKernels();

    /// Pulls `frames` into `inputStorage` from offset 0, in sub-pulls of at most `maximumFrames`.
    AUAudioUnitStatus pull(const AudioTimeStamp *timestamp, AUAudioFrameCount frames,
                           AURenderPullInputBlock __unsafe_unretained pullInputBlock);

  public:
    TimePitchDSP();
    ~TimePitchDSP() override;

    void setQuality(TimePitchDSPQuality newQuality);
    double holdStartUntilSampleTime(double sampleTime);
    void holdStartUntilHostTime(uint64_t hostTime);
    double latencyAtRate(double rate);
    int64_t framesPulled() const { return inputFramesPulled.load(std::memory_order_relaxed); }

    void setParameter(AUParameterAddress address, AUValue value, bool immediate) override;
    float getParameter(AUParameterAddress address) override;
    void startRamp(const AUParameterEvent &event) override;

    void init(int channelCount, double sampleRate) override;
    void deinit() override;
    void setMaximumFramesToRender(AUAudioFrameCount frames) override;
    void reset() override;
    double latencySeconds() override;

    AUAudioUnitStatus render(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                             AUAudioFrameCount frameCount, AudioBufferList *outputData, const AURenderEvent *events,
                             AURenderPullInputBlock __unsafe_unretained pullInputBlock) override;

    void process(FrameRange range) override {}
};
