#pragma once
// Shared present cadence — must match fpga/Plex_MiSTer/rtl/present_cadence.sv
//
// At display tick n (n = 0,1,2,…):
//   content_index = floor(n * content_fps / display_hz)
// Advance a unique frame when content_index increases vs the previous tick
// (tick 0 always advances to show the first unique).

#include <cstdint>

namespace misterplex {

inline std::uint32_t content_index_at(std::uint32_t display_index, int content_fps, int display_hz) {
    if (content_fps <= 0 || display_hz <= 0)
        return display_index;
    if (content_fps >= display_hz)
        return display_index;
    return static_cast<std::uint32_t>(
        (static_cast<std::uint64_t>(display_index) * static_cast<std::uint32_t>(content_fps)) /
        static_cast<std::uint32_t>(display_hz));
}

inline bool should_advance_unique(std::uint32_t display_index, int content_fps, int display_hz) {
    if (content_fps <= 0 || display_hz <= 0 || content_fps >= display_hz)
        return true;
    if (display_index == 0)
        return true;
    return content_index_at(display_index, content_fps, display_hz) !=
           content_index_at(display_index - 1, content_fps, display_hz);
}

// Count unique advances over N display ticks starting at display_index 0.
inline int unique_frames_in(int display_ticks, int content_fps, int display_hz) {
    int advances = 0;
    for (int n = 0; n < display_ticks; ++n) {
        if (should_advance_unique(static_cast<std::uint32_t>(n), content_fps, display_hz))
            ++advances;
    }
    return advances;
}

} // namespace misterplex
