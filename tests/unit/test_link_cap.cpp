#include "libmisterplex/link_cap.hpp"

#include <cstdio>
#include <string>
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

    // Empty → NO-DATA, never 0-as-capacity.
    {
        auto r = recommendLinkCapFromWindowBps({});
        CHECK(r.linkCapKbit == 0);
        CHECK(r.detail.find("NO-DATA") != std::string::npos);
    }

    // Parent-shaped: p95 high, min much lower — must NOT pick p95 as target.
    {
        std::vector<int64_t> w;
        // 60 windows: mostly ~144136 B/s, a few low like 45700.
        for (int i = 0; i < 54; ++i)
            w.push_back(144136);
        for (int i = 0; i < 6; ++i)
            w.push_back(45700);
        auto r = recommendLinkCapFromWindowBps(w, 0.85, 30);
        CHECK(r.nWindows == 60);
        CHECK(!r.provisional);
        CHECK(r.p95Bps >= r.medianBps);
        CHECK(r.linkCapKbit > 0);
        // p95 kbit ~ 161e3*8/1000*0.85 ≈ 1095 if p95 near high; request must be
        // at or below median*headroom and driven by p10 path — not p95 alone.
        const int p95Cap = bpsToLinkCapKbit(r.p95Bps, 0.85);
        CHECK(r.linkCapKbit <= p95Cap);
        CHECK(r.linkCapKbit <= bpsToLinkCapKbit(r.medianBps, 0.85) + 1);
        // Single-window observation is provisional.
        auto one = recommendLinkCapFromWindowBps({144136}, 0.85, 30);
        CHECK(one.provisional);
        std::printf("PASS link_cap parent-shaped cap=%d p10=%lld p95=%lld stat=%s\n",
                    r.linkCapKbit, (long long)r.p10Bps, (long long)r.p95Bps, r.statistic);
    }

    // Hysteresis: no raise after lower in same session; lower needs 3 streaks.
    {
        LinkCapHysteresisState st;
        auto d0 = stepLinkCapHysteresis(st, 1150, false, true);
        CHECK(d0.action == std::string("init"));
        CHECK(st.currentKbit == 1150);
        // One starved proposal — hold.
        auto d1 = stepLinkCapHysteresis(st, 900, true, false);
        CHECK(!d1.changed);
        CHECK(st.currentKbit == 1150);
        stepLinkCapHysteresis(st, 900, true, false);
        auto d3 = stepLinkCapHysteresis(st, 900, true, false);
        CHECK(d3.changed);
        CHECK(d3.action == std::string("lower"));
        CHECK(st.currentKbit == 900);
        // Healthy higher proposal — session sticky blocks raise.
        for (int i = 0; i < 12; ++i)
            stepLinkCapHysteresis(st, 1300, false, true);
        CHECK(st.currentKbit == 900);
        std::printf("PASS hysteresis session-sticky after lower\n");
    }

    // Delivered geometry bits/pixel — request must not assume 624x480 pixels.
    {
        const double bpp480 = requestedBitsPerDeliveredPixel(2000, 624, 480, 24.0);
        const double bpp350 = requestedBitsPerDeliveredPixel(2000, 624, 350, 24.0);
        CHECK(bpp350 > bpp480); // same kbit over fewer pixels → denser
        CHECK(bpp350 > 0.0);
    }

    if (fails) {
        std::fprintf(stderr, "test_link_cap: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_link_cap: OK\n");
    return 0;
}
