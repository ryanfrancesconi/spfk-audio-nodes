// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#include "AutomationScheduler.hpp"

#include <algorithm>
#include <mach/mach_time.h>

#include "AutomationFill.hpp"
#include "DSPBase.hpp"
#import "ParameterRamper.h"

// MARK: - C entry points

void publishAutomationDSP(DSPRef pDSP, const DSPAutomationLane *lanes, long laneCount, SPFKTimelineMapping mapping,
                          DSPAutomationAnchor anchor, const DSPRateChange *changes, long changeCount, bool glides) {
    auto snapshot = new AutomationSnapshot{{}, mapping, anchor, {}, {}, glides};
    snapshot->lanes.reserve(laneCount);

    if (changes != nullptr && changeCount > 0) {
        snapshot->changes.assign(changes, changes + changeCount);
        snapshot->changeSamples.assign(size_t(changeCount), 0);
    }

    for (long i = 0; i < laneCount; ++i) {
        const DSPAutomationLane &lane = lanes[i];
        if (lane.segmentCount <= 0 || lane.segments == nullptr) continue;

        snapshot->lanes.push_back({lane.address, lane.multiplies, lane.mode,
                                   std::vector<SPFKCurveSegment>(lane.segments, lane.segments + lane.segmentCount)});
    }

    pDSP->automation.publish(snapshot);
}

void drainRetiredAutomationDSP(DSPRef pDSP) { pDSP->automation.drainRetired(); }

AUValue renderedValueDSP(DSPRef pDSP, AUParameterAddress address) { return pDSP->automation.renderedValue(address); }

DSPRenderClock renderClockDSP(DSPRef pDSP) { return pDSP->automation.renderClock(); }

void setParameterTouchedDSP(DSPRef pDSP, AUParameterAddress address, bool touched) {
    pDSP->automation.setTouched(address, touched);
}

// MARK: - Lifetime

AutomationScheduler::AutomationScheduler() {
    std::fill(laneOfParameter, laneOfParameter + maxParameters, -1);
    std::fill(cursor, cursor + maxParameters, -2);
    std::fill(lastAutomated, lastAutomated + maxParameters, 0.f);
    std::fill(hasRendered, hasRendered + maxParameters, false);
    std::fill(glidePending, glidePending + maxParameters, false);
    std::fill(glideFrom, glideFrom + maxParameters, 0.f);
    std::fill(glideOffset, glideOffset + maxParameters, 0.f);
    std::fill(glideRemaining, glideRemaining + maxParameters, 0u);
    for (auto &value : rendered) value.store(0.f);
    for (auto &value : touched) value.store(false);
    std::fill(manualWins, manualWins + maxParameters, false);
    std::fill(latched, latched + maxParameters, false);

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    hostSecondsPerTick = double(timebase.numer) / double(timebase.denom) * 1e-9;
}

AutomationScheduler::~AutomationScheduler() {
    drainRetired();
    delete pending.exchange(nullptr);
    delete current;
}

void AutomationScheduler::allocate(int parameterCount, AUAudioFrameCount maximumFrames, double sampleRate,
                                   ParameterRamper *const *rampers) {
    this->parameterCount = std::min(parameterCount, maxParameters);
    this->maximumFrames = maximumFrames;
    this->sampleRate = sampleRate;
    glideFrames = uint32_t(sampleRate * 0.02);
    buffers.assign(size_t(this->parameterCount) * maximumFrames, 0.f);

    for (int i = 0; i < this->parameterCount; ++i) {
        rendered[i].store(rampers[i]->getLastValue());
    }
}

// MARK: - Publishing thread

void AutomationScheduler::publish(AutomationSnapshot *snapshot) {
    // A snapshot still pending was never adopted, so nothing else holds it.
    delete pending.exchange(snapshot, std::memory_order_acq_rel);
    drainRetired();
}

void AutomationScheduler::drainRetired() {
    uint32_t tail = retiredTail.load(std::memory_order_relaxed);
    uint32_t head = retiredHead.load(std::memory_order_acquire);

    while (tail != head) {
        delete retired[tail % retireCapacity];
        ++tail;
    }

    retiredTail.store(tail, std::memory_order_release);
}

void AutomationScheduler::setTouched(AUParameterAddress address, bool isTouched) {
    if (address >= AUParameterAddress(maxParameters)) return;
    touched[address].store(isTouched, std::memory_order_relaxed);
}

float AutomationScheduler::renderedValue(AUParameterAddress address) const {
    if (address >= AUParameterAddress(parameterCount)) return 0.f;
    return rendered[address].load(std::memory_order_relaxed);
}

// MARK: - Render thread

void AutomationScheduler::beginBlock(const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount,
                                     ParameterRamper *const *rampers) {
    if (maximumFrames == 0) return;

    publishClock(timestamp, frameCount);

    uint32_t head = retiredHead.load(std::memory_order_relaxed);
    bool canRetire = head - retiredTail.load(std::memory_order_acquire) < retireCapacity;

    if (current == nullptr || canRetire) {
        if (auto snapshot = pending.exchange(nullptr, std::memory_order_acq_rel)) {
            adopt(snapshot, timestamp, rampers);
        }
    }

    if (current == nullptr) return;

    bool hasAnchor = !current->lanes.empty();
    if (clockHasAnchor.load(std::memory_order_relaxed) != hasAnchor ||
        clockAnchor.load(std::memory_order_relaxed) != current->mapping.renderAnchor) {
        uint32_t sequence = clockSequence.load(std::memory_order_relaxed);
        clockSequence.store(sequence + 1, std::memory_order_release);
        clockAnchor.store(current->mapping.renderAnchor, std::memory_order_relaxed);
        clockHasAnchor.store(hasAnchor, std::memory_order_relaxed);
        clockSequence.store(sequence + 2, std::memory_order_release);
    }

    AUAudioFrameCount frames = std::min(frameCount, maximumFrames);
    int64_t firstSample = int64_t(timestamp->mSampleTime);
    foldChanges(firstSample);

    for (int parameter = 0; parameter < parameterCount; ++parameter) {
        int lane = laneOfParameter[parameter];
        if (lane < 0) continue;

        const AutomationLane &automation = current->lanes[lane];
        float *values = &buffers[size_t(parameter) * maximumFrames];

        fill(automation, parameter, firstSample, frames, values);

        if (yieldsToManual(parameter, automation)) {
            if (!manualWins[parameter]) {
                manualWins[parameter] = true;
                rampers[parameter]->detachAutomation(glideFrames);
            }
            continue;
        }

        if (manualWins[parameter]) {
            // Back from the parameter's own value to the curve, as a replacement glides.
            manualWins[parameter] = false;
            glidePending[parameter] = glideFrames > 0;
            glideFrom[parameter] = rampers[parameter]->getLastValue();
            glideRemaining[parameter] = 0;
        }

        applyGlide(parameter, values, frames);
        lastAutomated[parameter] = values[frames - 1];
        hasRendered[parameter] = true;

        rampers[parameter]->setAutomation(values, automation.multiplies);
    }

    foldChanges(firstSample + frames);
}

void AutomationScheduler::foldChanges(int64_t throughSample) {
    while (nextChange < current->changes.size() && current->changeSamples[nextChange] <= throughSample) {
        activeMapping = spfk_timeline_fold(&activeMapping, current->changeSamples[nextChange],
                                           current->changes[nextChange].rate);
        ++nextChange;
    }
}

void AutomationScheduler::fill(const AutomationLane &lane, int parameter, int64_t firstSample,
                               AUAudioFrameCount frames, float *values) {
    // Every lane splits at the same changes, so each starts from the block's mapping and only
    // `foldChanges` advances it.
    SPFKTimelineMapping mapping = activeMapping;
    size_t change = nextChange;
    AUAudioFrameCount done = 0;

    while (done < frames) {
        AUAudioFrameCount run = frames - done;

        if (change < current->changes.size()) {
            int64_t offset = current->changeSamples[change] - (firstSample + done);

            if (offset <= 0) {
                mapping = spfk_timeline_fold(&mapping, current->changeSamples[change], current->changes[change].rate);
                ++change;
                continue;
            }

            if (offset < int64_t(run)) run = AUAudioFrameCount(offset);
        }

        spfk_fill_automation(lane.segments.data(), long(lane.segments.size()), &mapping, firstSample + done, run,
                             &cursor[parameter], values + done);
        done += run;
    }
}

void AutomationScheduler::endBlock(ParameterRamper *const *rampers) {
    for (int parameter = 0; parameter < parameterCount; ++parameter) {
        rendered[parameter].store(rampers[parameter]->getLastValue(), std::memory_order_relaxed);
    }
}

void AutomationScheduler::adopt(AutomationSnapshot *snapshot, const AudioTimeStamp *timestamp,
                                ParameterRamper *const *rampers) {
    // What the outgoing automation would render on this frame, which a replacement glides from. Read
    // before retiring it: once retired, the publishing thread may free it.
    int64_t firstSample = int64_t(timestamp->mSampleTime);

    for (int parameter = 0; parameter < parameterCount; ++parameter) {
        int lane = laneOfParameter[parameter];
        if (lane < 0 || current == nullptr || !hasRendered[parameter]) continue;

        const AutomationLane &outgoing = current->lanes[lane];
        float value;
        spfk_fill_automation(outgoing.segments.data(), long(outgoing.segments.size()), &activeMapping, firstSample, 1,
                             &cursor[parameter], &value);

        if (glideRemaining[parameter] > 0) {
            value += glideOffset[parameter] * float(glideRemaining[parameter]) / float(glideFrames);
        }
        lastAutomated[parameter] = value;
    }

    if (current) {
        uint32_t head = retiredHead.load(std::memory_order_relaxed);
        retired[head % retireCapacity] = current;
        retiredHead.store(head + 1, std::memory_order_release);
    }

    current = snapshot;
    current->mapping.renderAnchor = bindAnchor(current->anchor, timestamp);

    for (size_t i = 0; i < current->changes.size(); ++i) {
        current->changeSamples[i] = bindAnchor(current->changes[i].effectiveFrom, timestamp);
    }

    activeMapping = current->mapping;
    nextChange = 0;

    int laneOf[maxParameters];
    std::fill(laneOf, laneOf + maxParameters, -1);

    for (size_t lane = 0; lane < current->lanes.size(); ++lane) {
        AUParameterAddress address = current->lanes[lane].address;
        if (address < AUParameterAddress(parameterCount) && laneOf[address] < 0) laneOf[address] = int(lane);
    }

    for (int parameter = 0; parameter < parameterCount; ++parameter) {
        bool wasAutomated = laneOfParameter[parameter] >= 0;
        latched[parameter] = false;

        if (laneOf[parameter] >= 0) {
            // Replacing running automation glides from where it was; a first snapshot starts on its curve.
            glidePending[parameter] = current->glides && wasAutomated && hasRendered[parameter] && glideFrames > 0;

            // A start opens on its curve, so the parameter's own value cannot still be returning
            // from a stop: that glide would scale a multiplying curve.
            if (!current->glides) rampers[parameter]->settle();
            glideFrom[parameter] = lastAutomated[parameter];
            glideRemaining[parameter] = 0;
            cursor[parameter] = -2;
        } else if (wasAutomated) {
            if (!manualWins[parameter]) rampers[parameter]->detachAutomation(glideFrames);
            manualWins[parameter] = false;
            hasRendered[parameter] = false;
        }

        laneOfParameter[parameter] = laneOf[parameter];
    }
}

int64_t AutomationScheduler::bindAnchor(const DSPAutomationAnchor &anchor, const AudioTimeStamp *timestamp) const {
    int64_t blockStart = int64_t(timestamp->mSampleTime);

    switch (anchor.kind) {
    case DSPAutomationAnchorSample:
        return anchor.sampleTime;

    case DSPAutomationAnchorAtAdoption:
        return blockStart;

    case DSPAutomationAnchorHost: {
        if (!(timestamp->mFlags & kAudioTimeStampHostTimeValid)) return blockStart;

        double ticks = anchor.hostTime >= timestamp->mHostTime ? double(anchor.hostTime - timestamp->mHostTime)
                                                               : -double(timestamp->mHostTime - anchor.hostTime);
        double rateScalar = (timestamp->mFlags & kAudioTimeStampRateScalarValid) && timestamp->mRateScalar > 0
                                ? timestamp->mRateScalar
                                : 1.0;

        // mRateScalar is actual host ticks per frame over nominal.
        double frames = ticks * hostSecondsPerTick * sampleRate / rateScalar;
        return blockStart + int64_t(llround(frames));
    }
    }

    return blockStart;
}

void AutomationScheduler::publishClock(const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount) {
    bool hostValid = timestamp->mFlags & kAudioTimeStampHostTimeValid;
    bool rateValid = (timestamp->mFlags & kAudioTimeStampRateScalarValid) && timestamp->mRateScalar > 0;

    int64_t ahead = hostValid ? int64_t(timestamp->mHostTime) - int64_t(mach_absolute_time()) : 0;
    aheadWindow[aheadIndex++ % 8] = ahead;
    int64_t largestAhead = *std::max_element(aheadWindow, aheadWindow + 8);

    uint32_t sequence = clockSequence.load(std::memory_order_relaxed);
    clockSequence.store(sequence + 1, std::memory_order_release);
    clockSample.store(int64_t(timestamp->mSampleTime), std::memory_order_relaxed);
    clockAhead.store(largestAhead, std::memory_order_relaxed);
    clockHost.store(hostValid ? timestamp->mHostTime : 0, std::memory_order_relaxed);
    clockRateScalar.store(rateValid ? timestamp->mRateScalar : 1.0, std::memory_order_relaxed);
    clockFrames.store(frameCount, std::memory_order_relaxed);
    clockSequence.store(sequence + 2, std::memory_order_release);
}

DSPRenderClock AutomationScheduler::renderClock() const {
    DSPRenderClock clock{};
    uint32_t before, after;

    do {
        before = clockSequence.load(std::memory_order_acquire);
        clock.sampleTime = clockSample.load(std::memory_order_relaxed);
        clock.hostTime = clockHost.load(std::memory_order_relaxed);
        clock.rateScalar = clockRateScalar.load(std::memory_order_relaxed);
        clock.frameCount = clockFrames.load(std::memory_order_relaxed);
        clock.renderAheadTicks = clockAhead.load(std::memory_order_relaxed);
        clock.anchorSample = clockAnchor.load(std::memory_order_relaxed);
        clock.hasAnchor = clockHasAnchor.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        after = clockSequence.load(std::memory_order_relaxed);
    } while (before != after || (before & 1));

    clock.valid = before > 0 && clock.hostTime != 0;
    clock.sampleRate = sampleRate;
    return clock;
}

bool AutomationScheduler::yieldsToManual(int parameter, const AutomationLane &lane) {
    if (lane.multiplies) return false;

    bool isTouched = touched[parameter].load(std::memory_order_relaxed);

    switch (lane.mode) {
    case DSPAutomationModeRead:
        return false;
    case DSPAutomationModeTouch:
        return isTouched;
    case DSPAutomationModeLatch:
        latched[parameter] = latched[parameter] || isTouched;
        return latched[parameter];
    }

    return false;
}

void AutomationScheduler::applyGlide(int parameter, float *values, AUAudioFrameCount frameCount) {
    if (glidePending[parameter]) {
        glidePending[parameter] = false;
        glideOffset[parameter] = glideFrom[parameter] - values[0];
        glideRemaining[parameter] = glideFrames;
    }

    for (AUAudioFrameCount i = 0; i < frameCount && glideRemaining[parameter] > 0; ++i) {
        values[i] += glideOffset[parameter] * float(glideRemaining[parameter]) / float(glideFrames);
        --glideRemaining[parameter];
    }
}
