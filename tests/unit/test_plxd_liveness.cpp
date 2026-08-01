// PLXD liveness: counter motion ≠ swap-live (c5382bee freeze class).
// true rc direct.

#include "libmisterplex/plxd_liveness.hpp"

#include <cstdio>
#include <cstring>
#include <string>

namespace {

int g_fails = 0;
#define EXPECT(c, m)                                                                               \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "FAIL: %s\n", m);                                                 \
            ++g_fails;                                                                             \
        }                                                                                          \
    } while (0)

} // namespace

int main() {
    using namespace misterplex;
    std::printf("PRE-REGISTER c5382bee freeze-blindness:\n");
    std::printf("  fd advances every vsync + swap frozen → OLD defence green, NEW swap_stuck\\n");
    std::printf("  counter alone must NEVER set swap_live\n");

    // 1) Vsync-packed: fd += 1 each sample, swap_pending stuck true, disp fixed
    {
        PlxdLivenessState st;
        bool saw_stuck = false;
        bool ever_swap_live = false;
        uint16_t fd = 100;
        for (int i = 0; i < 40; ++i) {
            // Always swap_pending, disp never moves → freeze
            auto o = plxdLivenessObserve(st, fd, /*disp=*/0, /*swap_pending=*/true);
            if (o.swap_live)
                ever_swap_live = true;
            if (o.swap_pending_stuck)
                saw_stuck = true;
            fd = static_cast<uint16_t>(fd + 1); // vsync-like every sample
        }
        EXPECT(saw_stuck, "vsync+swap_pending stuck detected");
        EXPECT(!ever_swap_live, "counter motion must not set swap_live");
        EXPECT(st.counter_moving_proven, "counter moving proven");
        EXPECT(st.semantics == PlxdCounterSemantics::VsyncPackedSuspect ||
                   st.semantics == PlxdCounterSemantics::SwapCounter ||
                   st.semantics == PlxdCounterSemantics::Unknown,
               "semantics classified or pending");
        // With Δ=1 every sample, semantics → SwapCounter (looks like swap rate).
        // That is OK: swap_pending_stuck still fires. Real c5382bee has Δ≥2 at
        // 24fps publish; simulate that next.
        std::printf("case1 stuck=%d swap_live_ever=%d semantics=%s\n", saw_stuck ? 1 : 0,
                    ever_swap_live ? 1 : 0, plxdSemanticsLabel(st.semantics));
    }

    // 2) c5382bee-class: Δfd=3 per observe, swap_pending stuck
    {
        PlxdLivenessState st;
        bool saw_stuck = false;
        uint16_t fd = 0;
        for (int i = 0; i < 50; ++i) {
            auto o = plxdLivenessObserve(st, fd, 0, true);
            if (o.swap_pending_stuck)
                saw_stuck = true;
            EXPECT(!o.swap_live || st.swap_progress_proven, "no swap_live without progress");
            fd = static_cast<uint16_t>(fd + 3);
        }
        EXPECT(saw_stuck, "c5382bee Δ=3 swap_pending stuck");
        EXPECT(st.semantics == PlxdCounterSemantics::VsyncPackedSuspect,
               "LIKELY vsync packed semantics");
        std::printf("case2 stuck=%d semantics=%s\n", saw_stuck ? 1 : 0,
                    plxdSemanticsLabel(st.semantics));
    }

    // 3) Healthy product: fd+=1, swap_pending clears, disp flips after publish
    {
        PlxdLivenessState st;
        uint16_t fd = 10;
        uint8_t disp = 0;
        plxdLivenessNotePublished(st, 1);
        bool ack = false;
        for (int i = 0; i < 20; ++i) {
            const bool pend = (i < 2);
            if (i == 3)
                disp = 1; // display shows published bank
            auto o = plxdLivenessObserve(st, fd, disp, pend);
            if (!st.await_display_ack)
                ack = true;
            EXPECT(!o.swap_pending_stuck, "healthy no pend stuck");
            EXPECT(!o.display_ack_stuck, "healthy no ack stuck");
            fd = static_cast<uint16_t>(fd + 1);
        }
        EXPECT(ack, "display ack completed");
        EXPECT(st.swap_progress_proven, "swap progress proven via ack");
        auto o = plxdLivenessObserve(st, fd, disp, false);
        EXPECT(o.swap_live, "healthy swap_live after ack");
        std::printf("case3 ack ok swap_live=%d\n", o.swap_live ? 1 : 0);
    }

    // 4) Residue: counter never moves
    {
        PlxdLivenessState st;
        bool stale = false;
        for (int i = 0; i < 15; ++i) {
            auto o = plxdLivenessObserve(st, /*fd=*/7, 0, false);
            if (o.residue_counter_stale)
                stale = true;
        }
        EXPECT(stale, "residue counter stale");
        std::printf("case4 residue_stale=%d\n", stale ? 1 : 0);
    }

    // 5) Display-ack stuck: publish bank1, disp stays 0, fd advances
    {
        PlxdLivenessState st;
        plxdLivenessNotePublished(st, 1);
        bool stuck = false;
        uint16_t fd = 0;
        for (int i = 0; i < 60; ++i) {
            auto o = plxdLivenessObserve(st, fd, /*disp=*/0, false);
            if (o.display_ack_stuck)
                stuck = true;
            fd = static_cast<uint16_t>(fd + 1);
        }
        EXPECT(stuck, "display_ack_stuck");
        std::printf("case5 display_ack_stuck=%d\n", stuck ? 1 : 0);
    }

    if (g_fails) {
        std::fprintf(stderr, "%d plxd_liveness fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_plxd_liveness\n");
    return 0;
}
