// Publish swap-delta ledger: Δframes_done + phase ESTIMATE (w-geom).
// PRE-REGISTER printed first. true rc direct.

#include "libmisterplex/publish_swap_delta_ledger.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
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
    std::printf("PRE-REGISTER swap-delta (parent ERROR 21):\n");
    std::printf("  delta0 => zero-refresh skip (pending overwrite)\n");
    std::printf("  delta1 => previous frame swapped before next publish\n");
    std::printf("  p_ge50<0.03 => ARM_EXONERATED_FPGA_SIDE (CDC redirect)\n");
    std::printf("  p_ge50 in [0.09,0.11] => ARM_LATE_MATCH_HOLD45\n");
    std::printf("  phase_est = mono%%16666 tag=ESTIMATE_60Hz (vsync_toggle not ARM-readable)\n");

    using misterplex::PublishSwapDeltaLedger;

    // Healthy free-gated: fd advances by 1 each publish, ideal interval
    {
        PublishSwapDeltaLedger L;
        const int64_t step = 1000000 / 24;
        int64_t t = 1'000'000;
        uint16_t fd = 10;
        for (int i = 0; i < 300; ++i) {
            L.note(t, fd, 0, 1, 0);
            t += step;
            fd = static_cast<uint16_t>(fd + 1);
        }
        const auto s = L.summarize();
        std::printf("healthy %s\n", L.formatSummaryLine("synthetic").c_str());
        std::printf("healthy %s\n", L.formatPhaseLine().c_str());
        EXPECT(s.pairs == 299, "healthy pairs");
        EXPECT(s.p_delta0 < 0.001, "healthy no delta0");
        EXPECT(s.p_delta1 > 0.99, "healthy almost all delta1");
        EXPECT(std::string(s.interval_verdict) == "ARM_EXONERATED_FPGA_SIDE",
               "healthy interval exonerates ARM");
        EXPECT(std::string(s.skip_verdict) == "NO_ZERO_REFRESH_SKIP", "healthy no skip");
    }

    // Overwrite class: every other publish same fd (delta0 ~50%)
    {
        PublishSwapDeltaLedger L;
        const int64_t step = 1000000 / 24;
        int64_t t = 1'000'000;
        uint16_t fd = 100;
        for (int i = 0; i < 200; ++i) {
            L.note(t, fd, 1, 0, 0);
            t += step;
            if ((i % 2) == 1)
                fd = static_cast<uint16_t>(fd + 1);
        }
        const auto s = L.summarize();
        std::printf("overwrite %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.p_delta0 > 0.4 && s.p_delta0 < 0.6, "overwrite ~50% delta0");
        EXPECT(std::string(s.skip_verdict) == "ZERO_REFRESH_SKIPS_PRESENT",
               "overwrite skip verdict");
    }

    // uint16 wrap: 65535 -> 0 is delta 1
    {
        PublishSwapDeltaLedger L;
        L.note(1000, 65535, 0, 1, 0);
        L.note(1000 + 41666, 0, 0, 1, 0);
        EXPECT(L.delta1 == 1 && L.delta0 == 0, "uint16 wrap delta=1");
        std::printf("PASS uint16_wrap_delta1\n");
    }

    if (g_fails) {
        std::fprintf(stderr, "%d publish_swap_delta fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_publish_swap_delta_ledger\n");
    return 0;
}
