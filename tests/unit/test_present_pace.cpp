// present_pace behavioral + judder policy gates (fab-pace).
#include "libmisterplex/present_pace.hpp"
#include "libmisterplex/cadence.hpp"

#include <cstdio>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static void checkCadenceLockstep() {
    // 60 ticks @ 24/60 → 24 unique (2:3)
    CHECK(misterplex::present_pace::unique24in60(60) == 24);
    CHECK(misterplex::unique_frames_in(60, 24, 60) == 24);
    // 24/60 floor: n=0 adv, n=1-2 hold, n=3 adv (content 0→1)
    CHECK(misterplex::should_advance_unique(0, 24, 60));
    CHECK(!misterplex::should_advance_unique(1, 24, 60));
    CHECK(!misterplex::should_advance_unique(2, 24, 60));
    CHECK(misterplex::should_advance_unique(3, 24, 60));
}

static void checkLegacyEnableOff() {
    misterplex::present_pace::State s;
    s.enable = false;
    // No pending → repeat
    CHECK(!misterplex::present_pace::vsync(s, true, 24, 60));
    CHECK(s.c.repeats == 1);
    // Ring + vsync → swap
    misterplex::present_pace::ring(s, true);
    CHECK(misterplex::present_pace::vsync(s, true, 24, 60));
    CHECK(s.disp_bank == true);
    CHECK(s.c.presented == 1);
}

static void checkEnableOnLateRepeat() {
    misterplex::present_pace::State s;
    s.enable = true;
    // Advance wanted on tick 0, nothing pending → late repeat
    CHECK(!misterplex::present_pace::vsync(s, true, 24, 60));
    CHECK(s.c.late == 1);
    CHECK(s.c.repeats == 1);
    CHECK(s.c.presented == 0);
    CHECK(!s.has_frame); // never showed a frame — still not black policy for has_frame
}

static void checkEnableOnEarlyHold() {
    misterplex::present_pace::State s;
    s.enable = true;
    misterplex::present_pace::ring(s, false);
    // Tick 0 advances + swaps
    CHECK(misterplex::present_pace::vsync(s, true, 24, 60));
    CHECK(s.c.presented == 1);
    // Ring early for next
    misterplex::present_pace::ring(s, true);
    // Tick 1 holds (24/60)
    CHECK(!misterplex::present_pace::vsync(s, true, 24, 60));
    CHECK(s.c.early_hold == 1);
    CHECK(s.swap_pending);
    CHECK(s.disp_bank == false); // still first bank
}

static void checkDropCounter() {
    misterplex::present_pace::State s;
    s.enable = true;
    misterplex::present_pace::ring(s, false);
    misterplex::present_pace::ring(s, true); // drop
    CHECK(s.c.drops == 1);
    CHECK(s.pending_bank == true);
}

static void check24in60Presented() {
    misterplex::present_pace::State s;
    s.enable = true;
    // Producer always ready one frame ahead on every unique tick
    for (int n = 0; n < 60; ++n) {
        if (misterplex::should_advance_unique(static_cast<std::uint32_t>(n), 24, 60))
            misterplex::present_pace::ring(s, static_cast<bool>(n & 1));
        misterplex::present_pace::vsync(s, true, 24, 60);
    }
    std::fprintf(stderr, "24in60 presented=%u repeats=%u early=%u late=%u\n", s.c.presented,
                 s.c.repeats, s.c.early_hold, s.c.late);
    CHECK(s.c.presented == 24);
    CHECK(s.c.vsync == 60);
    CHECK(s.c.late == 0);
}

int main() {
    checkCadenceLockstep();
    checkLegacyEnableOff();
    checkEnableOnLateRepeat();
    checkEnableOnEarlyHold();
    checkDropCounter();
    check24in60Presented();
    if (fails) {
        std::fprintf(stderr, "test_present_pace: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_present_pace: PASS\n");
    return 0;
}
