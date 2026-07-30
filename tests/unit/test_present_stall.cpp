// Present-stall detector: green path + mutation twins that encode f1128b0 defects.
// Pre-register:
//   deliberate skip ×80 → must NOT stall
//   attempt fail ×72 → must stall once
//   ok after stall → re-arm; fail ×72 again → stall again
//   FAULT_COUNT_SKIP twin → stalls on skips (RED vs product)
//   FAULT_NO_REARM twin → second stall episode silent (RED vs product)
#include "libmisterplex/present_stall.hpp"

#include <cstdio>

using misterplex::kPresentStallThreshold;
using misterplex::PresentStallTracker;
using misterplex::PresentStallTrackerFaultyCountSkip;
using misterplex::PresentStallTrackerFaultyNoRearm;

static int g_fail = 0;

static void expect(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL %s\n", msg);
        ++g_fail;
    } else {
        std::printf("OK %s\n", msg);
    }
}

int main() {
    // --- product tracker: deliberate skip must not alarm ---
    {
        PresentStallTracker t;
        for (int i = 0; i < kPresentStallThreshold + 10; ++i)
            t.onDeliberateSkip();
        expect(!t.shouldLogStall(), "deliberate_skip_no_stall");
        expect(t.consecutive_fail == 0, "deliberate_skip_fail_count_zero");
    }

    // --- product: attempted failures trip once ---
    {
        PresentStallTracker t;
        for (int i = 0; i < kPresentStallThreshold - 1; ++i)
            t.onAttemptFailed();
        expect(!t.shouldLogStall(), "below_threshold_quiet");
        t.onAttemptFailed();
        expect(t.shouldLogStall(), "at_threshold_logs");
        expect(!t.shouldLogStall(), "second_poll_same_episode_quiet");
    }

    // --- product: recovery re-arms ---
    {
        PresentStallTracker t;
        for (int i = 0; i < kPresentStallThreshold; ++i)
            t.onAttemptFailed();
        expect(t.shouldLogStall(), "first_episode_logs");
        t.onAttemptOk();
        expect(t.consecutive_fail == 0, "ok_clears_fail_run");
        expect(t.stall_logged == false, "ok_rearms_logged_flag");
        for (int i = 0; i < kPresentStallThreshold; ++i)
            t.onAttemptFailed();
        expect(t.shouldLogStall(), "second_episode_logs_after_rearm");
    }

    // --- mutation: counting skips must differ from product (would fail if product counted) ---
    {
        PresentStallTracker good;
        PresentStallTrackerFaultyCountSkip bad;
        for (int i = 0; i < kPresentStallThreshold; ++i) {
            good.onDeliberateSkip();
            bad.onDeliberateSkip();
        }
        const bool good_stall = good.shouldLogStall();
        const bool bad_stall = bad.shouldLogStall();
        expect(!good_stall && bad_stall, "FAULT_COUNT_SKIP_red_vs_product");
    }

    // --- mutation: no re-arm must differ from product ---
    {
        PresentStallTracker good;
        PresentStallTrackerFaultyNoRearm bad;
        for (int i = 0; i < kPresentStallThreshold; ++i) {
            good.onAttemptFailed();
            bad.onAttemptFailed();
        }
        expect(good.shouldLogStall() && bad.shouldLogStall(), "both_log_first_episode");
        good.onAttemptOk();
        bad.onAttemptOk();
        for (int i = 0; i < kPresentStallThreshold; ++i) {
            good.onAttemptFailed();
            bad.onAttemptFailed();
        }
        const bool good2 = good.shouldLogStall();
        const bool bad2 = bad.shouldLogStall();
        expect(good2 && !bad2, "FAULT_NO_REARM_red_vs_product");
    }

    if (g_fail) {
        std::fprintf(stderr, "test_present_stall: %d FAIL\n", g_fail);
        return 1;
    }
    std::printf("test_present_stall: OK\n");
    return 0;
}
