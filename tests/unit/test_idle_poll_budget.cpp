// Idle-busyloop contract for misterplexd.
//
// Negative cases (a naive reintroduction of the hot loop MUST fail these):
//   1. kSpiAckBusySpinsBeforeYield raised above the ceiling (old code: 1e6).
//   2. kSpiAckMaxWallUs raised above the ceiling (old code: unbounded wall).
//   3. spiAckWait on a never-true pred completes without any yield.
//   4. consecutive busy peak exceeds kSpiAckBusySpinsBeforeYield.
//   5. idle SPI OSD quiet period drops below the multi-second floor.
//
// Positive: timeout path yields, progressive backoff invokes sleep, identity
// success path returns quickly with zero yields when pred is immediately true.

#include "libmisterplex/spi_ack_wait.hpp"

#include <cstdio>
#include <vector>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // --- Policy ceilings (RED if someone re-opens the 1e6 spin) ---------------
    CHECK(kSpiAckBusySpinsBeforeYield >= 1);
    CHECK(kSpiAckBusySpinsBeforeYield <= kSpiAckBusySpinsCeiling);
    CHECK(kSpiAckMaxWallUs >= 100);
    CHECK(kSpiAckMaxWallUs <= kSpiAckMaxWallUsCeiling);
    CHECK(kOsdSpiIdleQuietMs >= kOsdSpiIdleQuietMsFloor);
    CHECK(kOsdSpiPlayingQuietMs >= 250);
    CHECK(kOsdMailboxQuietMs >= 50);
    CHECK(kInputMailboxQuietMs >= 50);

    // Legacy 1e6-spin policy must NOT satisfy the ceiling (documents the defect).
    constexpr int kLegacyBusyCap = 1000000;
    CHECK(kLegacyBusyCap > kSpiAckBusySpinsCeiling);
    CHECK(kSpiAckBusySpinsBeforeYield < kLegacyBusyCap);

    // --- Immediate success: no sleep, no timeout ------------------------------
    {
        SpiAckWaitStats st;
        int sleeps = 0;
        const bool ok = spiAckWait([] { return true; }, st, [&](int) { ++sleeps; });
        CHECK(ok);
        CHECK(!st.timed_out);
        CHECK(st.busy_reads == 0);
        CHECK(st.yields == 0);
        CHECK(sleeps == 0);
    }

    // --- Never-ready pred: must time out AND yield at least once --------------
    {
        SpiAckWaitStats st;
        std::vector<int> sleep_args;
        const bool ok = spiAckWait([] { return false; }, st,
                                  [&](int us) { sleep_args.push_back(us); });
        CHECK(!ok);
        CHECK(st.timed_out);
        CHECK(st.yields >= 1);
        CHECK(static_cast<int>(sleep_args.size()) == st.yields);
        CHECK(st.consecutive_busy_peak <= kSpiAckBusySpinsBeforeYield);
        CHECK(st.consecutive_busy_peak >= 1);
        // Progressive backoff: first yield at floor, later args non-decreasing.
        // Guard empty: a no-yield legacy wait must fail above, not UB here.
        if (sleep_args.empty()) {
            CHECK(!sleep_args.empty());
        } else {
            CHECK(sleep_args.front() == kSpiAckYieldFloorUs);
            for (size_t i = 1; i < sleep_args.size(); ++i)
                CHECK(sleep_args[i] >= sleep_args[i - 1]);
            for (int us : sleep_args)
                CHECK(us <= kSpiAckYieldCapUs);
        }
    }

    // --- Succeeds after a few fails: peak still within budget -----------------
    {
        SpiAckWaitStats st;
        int n = 0;
        int sleeps = 0;
        const bool ok = spiAckWait(
            [&] {
                ++n;
                return n >= 3;
            },
            st, [&](int) { ++sleeps; });
        CHECK(ok);
        CHECK(!st.timed_out);
        CHECK(st.busy_reads == 2);
        CHECK(st.consecutive_busy_peak <= kSpiAckBusySpinsBeforeYield);
        // 2 fails < spins-before-yield → no sleep required.
        CHECK(sleeps == 0);
    }

    // --- osdPollQuietMs data-driven mapping -----------------------------------
    CHECK(osdPollQuietMs(true, false) == kOsdMailboxQuietMs);
    CHECK(osdPollQuietMs(true, true) == kOsdMailboxQuietMs);
    CHECK(osdPollQuietMs(false, true) == kOsdSpiPlayingQuietMs);
    CHECK(osdPollQuietMs(false, false) == kOsdSpiIdleQuietMs);
    // Negative: idle SPI must be strictly slower than playing SPI.
    CHECK(kOsdSpiIdleQuietMs > kOsdSpiPlayingQuietMs);

    if (fails) {
        std::fprintf(stderr, "test_idle_poll_budget: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_idle_poll_budget: OK\n");
    return 0;
}
