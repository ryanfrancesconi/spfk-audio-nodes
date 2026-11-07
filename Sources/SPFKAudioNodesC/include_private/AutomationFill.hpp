// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#pragma once

#include <stdint.h>

#include <CurveSegmentC.h>
#include <TimelineMappingC.h>

namespace AutomationFill {

/// Whether `index` is the segment `curveFind` returns for `position`.
inline bool cursorHolds(const CurveSegmentC *segments, long count, long index, double position) {
    if (index == -1) return segments[0].start > position;
    if (index < 0 || index >= count) return false;
    return segments[index].start <= position && (index + 1 == count || segments[index + 1].start > position);
}

/// Fills `values` with the curve at the mapping's position for each of `frames` render samples from
/// `firstSample`, exactly as `curveValue` evaluates it.
///
/// `cursor` is the segment the previous fill ended in, or -2 when unknown, and is updated. It is
/// checked, then its successor, then searched for, so a wrap, a reverse or a new mapping re-locates it.
inline void fill(const CurveSegmentC *segments, long count, const TimelineMappingC *mapping,
                 int64_t firstSample, uint32_t frames, long *cursor, float *values) {
    long index = *cursor;

    // Outside a segment the value is constant until the segment changes, so it is evaluated once.
    long heldIndex = -2;
    float held = 0;

    for (uint32_t i = 0; i < frames; ++i) {
        double position = timelinePosition(mapping, firstSample + i);

        if (!cursorHolds(segments, count, index, position)) {
            if (cursorHolds(segments, count, index + 1, position)) {
                ++index;
            } else {
                index = curveFind(segments, count, position);
            }
        }

        if (index < 0 || position >= segments[index].end) {
            if (heldIndex != index) {
                heldIndex = index;
                held = (float)(index < 0 ? curveSegmentStartValue(&segments[0])
                                         : curveSegmentValue(&segments[index], segments[index].end));
            }
            values[i] = held;
        } else {
            values[i] = (float)curveSegmentValue(&segments[index], position);
        }
    }

    *cursor = index;
}

} // namespace AutomationFill
