// PLXD liveness: bank-identity progress, not frames_done-only (c5382bee).
#include "libmisterplex/plxd_liveness.hpp"

#include <cstdio>
#include <cstdlib>

using misterplex::PlxdLivenessSample;
using misterplex::PlxdLivenessState;
using misterplex::plxdBankIdentitySig;
using misterplex::plxdLivenessShouldFallback;
using misterplex::plxdLivenessTick;

static int g_fail = 0;
#define EXPECT(cond, msg)                                                                          \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL: %s\n", msg);                                               \
            ++g_fail;                                                                              \
        }                                                                                          \
    } while (0)

int main() {
    // Signature ignores frames_done.
    PlxdLivenessSample a{100, 0x1, 0, false};
    PlxdLivenessSample b{200, 0x1, 0, false}; // fd advanced only
    PlxdLivenessSample c{200, 0x2, 1, false}; // identity moved
    EXPECT(plxdBankIdentitySig(a) == plxdBankIdentitySig(b), "fd-only same sig");
    EXPECT(plxdBankIdentitySig(a) != plxdBankIdentitySig(c), "disp/free change sig");

    // c5382bee freeze class: frames_done free-runs, banks stuck → STALE
    {
        PlxdLivenessState st;
        PlxdLivenessSample s{0, 0x1, 0, false};
        plxdLivenessTick(st, s); // baseline
        for (int i = 1; i <= 12; ++i) {
            s.frames_done = static_cast<uint16_t>(i * 3); // vsync pack advances
            plxdLivenessTick(st, s);
        }
        EXPECT(st.proven == false, "fd-only never proves");
        EXPECT(st.stale_count >= 10, "stale climbs despite fd advance");
        EXPECT(plxdLivenessShouldFallback(st, 10, 60), "fallback before proven");
        EXPECT(st.last_tick_fd_advanced == true, "diag: fd advanced on last tick");
        EXPECT(st.last_tick_sig_advanced == false, "diag: sig did not advance");
    }

    // Healthy swaps: identity flips → proven, stale 0
    {
        PlxdLivenessState st;
        PlxdLivenessSample s{0, 0x2, 0, false};
        plxdLivenessTick(st, s);
        s.frames_done = 1;
        s.free_bank_mask = 0x1;
        s.disp_bank = 1;
        plxdLivenessTick(st, s);
        EXPECT(st.proven == true, "identity move proves");
        EXPECT(st.stale_count == 0, "stale reset on progress");
        EXPECT(!plxdLivenessShouldFallback(st, 10, 60), "no fallback when live");
    }

    // Residue static: no fd, no sig → STALE
    {
        PlxdLivenessState st;
        PlxdLivenessSample s{5, 0x1, 0, false};
        for (int i = 0; i < 12; ++i)
            plxdLivenessTick(st, s);
        EXPECT(plxdLivenessShouldFallback(st, 10, 60), "static residue fallback");
    }

    // After proven, identity freeze with fd still moving → after-proven limit
    {
        PlxdLivenessState st;
        PlxdLivenessSample s{0, 0x2, 0, false};
        plxdLivenessTick(st, s);
        s.free_bank_mask = 0x1;
        s.disp_bank = 1;
        s.frames_done = 1;
        plxdLivenessTick(st, s);
        EXPECT(st.proven, "setup proven");
        for (int i = 0; i < 60; ++i) {
            s.frames_done = static_cast<uint16_t>(2 + i); // vsync only
            plxdLivenessTick(st, s);
        }
        EXPECT(plxdLivenessShouldFallback(st, 10, 60), "freeze after proven → fallback");
    }

    if (g_fail) {
        std::fprintf(stderr, "test_plxd_liveness FAIL count=%d\n", g_fail);
        return 1;
    }
    std::printf("OK test_plxd_liveness\n");
    return 0;
}
