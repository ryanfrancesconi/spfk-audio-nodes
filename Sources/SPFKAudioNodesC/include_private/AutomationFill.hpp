// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#pragma once

#include <stdint.h>

#include <SPFKCurve.h>

/// Whether `index` is the segment `spfk_curve_find` returns for `position`.
static inline bool spfk_automation_cursor_holds(const SPFKCurveSegment *segments, long count, long index,
                                                double position) {
    if (index == -1) return segments[0].start > position;
    if (index < 0 || index >= count) return false;
    return segments[index].start <= position && (index + 1 == count || segments[index + 1].start > position);
}

/// Fills `values` with the curve at the mapping's position for each of `frames` render samples from
/// `firstSample`, exactly as `spfk_curve_value` evaluates it.
///
/// `cursor` is the segment the previous fill ended in, or -2 when unknown, and is updated. It is
/// checked, then its successor, then searched for, so a wrap, a reverse or a new mapping re-locates it.
static inline void spfk_fill_automation(const SPFKCurveSegment *segments, long count,
                                        const SPFKTimelineMapping *mapping, int64_t firstSample,
                                        uint32_t frames, long *cursor, float *values) {
    long index = *cursor;

    // Outside a segment the value is constant until the segment changes, so it is evaluated once.
    long heldIndex = -2;
    float held = 0;

    for (uint32_t i = 0; i < frames; ++i) {
        double position = spfk_timeline_position(mapping, firstSample + i);

        if (!spfk_automation_cursor_holds(segments, count, index, position)) {
            if (spfk_automation_cursor_holds(segments, count, index + 1, position)) {
                ++index;
            } else {
                index = spfk_curve_find(segments, count, position);
            }
        }

        if (index < 0 || position >= segments[index].end) {
            if (heldIndex != index) {
                heldIndex = index;
                held = (float)(index < 0 ? spfk_curve_segment_value(&segments[0], segments[0].start)
                                         : spfk_curve_segment_value(&segments[index], segments[index].end));
            }
            values[i] = held;
        } else {
            values[i] = (float)spfk_curve_segment_value(&segments[index], position);
        }
    }

    *cursor = index;
}
