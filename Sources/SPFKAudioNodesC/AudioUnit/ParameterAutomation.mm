// Copyright Ryan Francesconi. All Rights Reserved.
// Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes
// Based on the AudioKit version. All Rights Reserved.

#include "ParameterAutomation.h"
#include <algorithm>
#include <iostream>
#include <list>
#include <mach/mach_time.h>
#include <map>
#include <utility>
#include <vector>

/// Returns a render observer block which will apply the automation to the
/// selected parameter.
extern "C" AURenderObserver ParameterAutomationGetRenderObserver(AUParameterAddress address,
                                                                 AUScheduleParameterBlock scheduleParameterBlock,
                                                                 double sampleRate, double startSampleTime,
                                                                 const struct AutomationEvent *eventsArray,
                                                                 size_t count) {
    //
    std::vector<AutomationEvent> events{eventsArray, eventsArray + count};

    // Sort events by start time.
    std::sort(events.begin(), events.end(), [](auto a, auto b) { return a.startTime < b.startTime; });

    __block size_t index = 0;

    return ^void(AudioUnitRenderActionFlags actionFlags, const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount,
                 NSInteger outputBusNumber) {
      if (!(actionFlags & kAudioUnitRenderAction_PreRender)) {
          return;
      }

      // Use double throughout to preserve precision against the engine's sample-time clock.
      double blockStartTime = (timestamp->mSampleTime - startSampleTime) / sampleRate;
      double blockEndTime = blockStartTime + frameCount / sampleRate;

      AUValue initial = NAN;

      // Skip over events completely in the past to determine
      // an initial value.
      for (; index < count; ++index) {
          auto event = events[index];

          if (!(event.startTime + event.rampDuration < blockStartTime)) {
              break;
          }

          initial = event.targetValue;
      }

      // Do we have an initial value from completed events?
      if (!isnan(initial)) {
          scheduleParameterBlock(AUEventSampleTimeImmediate, 0, address, initial);
      }

      // Apply parameter automation for the segment.
      while (index < count) {
          auto event = events[index];

          // Is it after the current block?
          if (event.startTime >= blockEndTime) {
              break;
          }

          // Signed frame offset from the start of this render block.
          int64_t sampleOffset = (int64_t)((event.startTime - blockStartTime) * sampleRate);
          int64_t rawDuration = (int64_t)(event.rampDuration * sampleRate);

          if (sampleOffset < 0) {
              // Event started before this block; shorten the ramp by the elapsed portion.
              rawDuration += sampleOffset;
              if (rawDuration <= 0) {
                  // Ramp already complete — apply target value immediately and move on.
                  scheduleParameterBlock(AUEventSampleTimeImmediate, 0, address, event.targetValue);
                  index++;
                  continue;
              }
              sampleOffset = 0;
          }

          scheduleParameterBlock((AUEventSampleTime)sampleOffset, (AUAudioFrameCount)rawDuration, address,
                                 event.targetValue);

          index++;
      }
    };
}
