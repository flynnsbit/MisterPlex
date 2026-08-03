#pragma once
// Behavioral model of present_pace_seq.sv — keep lockstep with RTL.
// Judder: fixed display_hz + content_fps floor cadence (2:3 at 24/60).

#include "libmisterplex/cadence.hpp"

#include <cstdint>

namespace misterplex {
namespace present_pace {

struct Counters {
    std::uint32_t presented = 0;
    std::uint32_t repeats = 0;
    std::uint32_t drops = 0;
    std::uint32_t late = 0;
    std::uint32_t early_hold = 0;
    std::uint32_t vsync = 0;
};

struct State {
    bool enable = false;
    bool disp_bank = false;
    bool has_frame = false;
    bool swap_pending = false;
    bool pending_bank = false;
    bool swap_req_seen = false;
    std::uint32_t display_index = 0;
    std::uint32_t content_index = 0;
    Counters c{};
};

// One producer doorbell edge.
inline void ring(State& s, bool bank) {
    if (s.swap_pending)
        s.c.drops++;
    s.swap_req_seen = !s.swap_req_seen;
    s.pending_bank = bank;
    s.swap_pending = true;
}

// One vsync pulse. pending_ready must reflect bank visibility.
inline bool vsync(State& s, bool pending_ready, int content_fps, int display_hz) {
    s.c.vsync++;
    bool adv = true;
    if (s.enable && content_fps > 0 && display_hz > 0 && content_fps < display_hz) {
        adv = should_advance_unique(s.display_index, content_fps, display_hz);
        if (adv) {
            s.content_index = content_index_at(s.display_index, content_fps, display_hz);
        }
    } else if (adv) {
        s.content_index++;
    }
    s.display_index++;

    bool did_swap = false;
    if (!s.enable) {
        if (s.swap_pending && pending_ready) {
            s.disp_bank = s.pending_bank;
            s.has_frame = true;
            s.swap_pending = false;
            s.c.presented++;
            did_swap = true;
        } else {
            s.c.repeats++;
            if (s.swap_pending && !pending_ready)
                s.c.late++;
        }
    } else if (adv) {
        if (s.swap_pending && pending_ready) {
            s.disp_bank = s.pending_bank;
            s.has_frame = true;
            s.swap_pending = false;
            s.c.presented++;
            did_swap = true;
        } else {
            s.c.repeats++;
            s.c.late++;
        }
    } else {
        s.c.repeats++;
        if (s.swap_pending && pending_ready)
            s.c.early_hold++;
    }
    return did_swap;
}

// 24-in-60 unique advances over N display ticks (must match cadence.hpp).
inline int unique24in60(int ticks) {
    return unique_frames_in(ticks, 24, 60);
}

} // namespace present_pace
} // namespace misterplex
