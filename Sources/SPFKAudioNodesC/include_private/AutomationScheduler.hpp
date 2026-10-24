// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#pragma once

#import <AudioToolbox/AudioToolbox.h>

#include <atomic>
#include <vector>

#include "AutomationDSP.h"

class ParameterRamper;

struct AutomationLane {
    AUParameterAddress address;
    bool multiplies;
    std::vector<SPFKCurveSegment> segments;
};

/// One published state of a node's automation. Immutable once published, except the anchor the
/// render thread binds on adoption.
struct AutomationSnapshot {
    std::vector<AutomationLane> lanes;
    SPFKTimelineMapping mapping;
    DSPAutomationAnchor anchor;
};

/// Hands automation snapshots to the render thread and evaluates them there, per frame, into a
/// buffer per parameter.
///
/// Adoption is one atomic exchange at the start of a block; a replaced snapshot goes into a
/// single-producer ring the publishing thread drains. With the ring full a snapshot waits in
/// `pending` for a later block, so a publish is delayed but never lost and never blocks.
class AutomationScheduler {
  public:
    static constexpr int maxParameters = 128;
    static constexpr uint32_t retireCapacity = 16;

    AutomationScheduler();
    ~AutomationScheduler();

    AutomationScheduler(const AutomationScheduler &) = delete;
    AutomationScheduler &operator=(const AutomationScheduler &) = delete;

    /// Sizes the buffers. With render resources deallocated only.
    void allocate(int parameterCount, AUAudioFrameCount maximumFrames, double sampleRate,
                  ParameterRamper *const *rampers);

    // MARK: Publishing thread

    void publish(AutomationSnapshot *snapshot);
    void drainRetired();
    float renderedValue(AUParameterAddress address) const;

    // MARK: Render thread

    /// Adopts a pending snapshot, fills this block's values and points each ramper at its own.
    void beginBlock(const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount, ParameterRamper *const *rampers);

    /// Records each parameter's last rendered value.
    void endBlock(ParameterRamper *const *rampers);

  private:
    std::atomic<AutomationSnapshot *> pending{nullptr};
    AutomationSnapshot *current = nullptr;

    AutomationSnapshot *retired[retireCapacity] = {};
    std::atomic<uint32_t> retiredHead{0}; // written by the render thread
    std::atomic<uint32_t> retiredTail{0}; // written by the publishing thread

    int parameterCount = 0;
    AUAudioFrameCount maximumFrames = 0;
    double sampleRate = 48000;
    uint32_t glideFrames = 0;
    double hostSecondsPerTick = 0;
    std::vector<float> buffers;

    int laneOfParameter[maxParameters];
    long cursor[maxParameters];
    float lastAutomated[maxParameters];
    bool hasRendered[maxParameters];
    bool glidePending[maxParameters];
    float glideFrom[maxParameters];
    float glideOffset[maxParameters];
    uint32_t glideRemaining[maxParameters];
    std::atomic<float> rendered[maxParameters];

    void adopt(AutomationSnapshot *snapshot, const AudioTimeStamp *timestamp, ParameterRamper *const *rampers);
    int64_t bindAnchor(const DSPAutomationAnchor &anchor, const AudioTimeStamp *timestamp) const;
    void applyGlide(int parameter, float *values, AUAudioFrameCount frameCount);
};
