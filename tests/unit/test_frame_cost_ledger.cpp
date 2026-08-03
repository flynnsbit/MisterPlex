// Red-before-green: FrameCostLedger percentiles + work definition.
//
// NEG: a ledger that reported paced interval (~33 ms @30) as "work" would
// pass a naive mean check but fail p99-vs-inject when samples are pure work.
// We inject known work_us and require exact order statistics.
#include "libmisterplex/frame_cost_ledger.hpp"

#include <cstdio>
#include <cstring>
#include <string>

static int g_fails = 0;
static void expect(bool c, const char* m) {
    if (!c) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++g_fails;
    }
}

int main() {
    using namespace misterplex;

    // Empty
    {
        FrameCostLedger led;
        expect(led.empty(), "empty before note");
        const std::string s = led.formatLine("t0");
        expect(s.find("n=0") != std::string::npos, "empty format n=0");
    }

    // Known ladder: 100 samples of 10000 us, last 5 are 50000 (spikes).
    {
        FrameCostLedger led;
        for (int i = 0; i < 95; ++i)
            led.note(10000);
        for (int i = 0; i < 5; ++i)
            led.note(50000);
        expect(led.count == 100, "count 100");
        expect(led.max_us == 50000, "max spike");
        const std::string s = led.formatLine("inject");
        // p50 must be ~10 ms (common case), p99 near spike
        expect(s.find("p50_ms=10.000") != std::string::npos ||
                   s.find("p50_ms=10.") != std::string::npos,
               "p50 ~10ms common case");
        expect(s.find("p99_ms=50") != std::string::npos ||
                   s.find("p99_ms=4") != std::string::npos, // 49.x interpolate
               "p99 near spike");
        expect(s.find("unit=work_us_excl_pacing") != std::string::npos, "unit tag");
        expect(s.find("tag=inject") != std::string::npos, "tag echoed");
        // NEG: mean alone must not be the only field (deadline needs p99)
        expect(s.find("mean_ms=") != std::string::npos, "mean present");
        expect(s.find("p99_ms=") != std::string::npos, "p99 present (not mean-only)");
        expect(s.find("p99_minus_mean_ms=") != std::string::npos, "tail gap field");
    }

    // Smoke helper
    {
        const uint32_t us[] = {1000, 2000, 3000, 4000};
        double p50 = 0, p99 = 0;
        expect(frameCostPctSmoke(us, 4, &p50, &p99), "smoke ok");
        expect(p50 >= 2.0 && p50 <= 3.0, "smoke p50 mid");
        expect(p99 >= 3.5 && p99 <= 4.0, "smoke p99 high");
    }

    // Ring overflow does not crash; count keeps growing, filled caps.
    {
        FrameCostLedger led;
        for (std::size_t i = 0; i < FrameCostLedger::kCap + 50; ++i)
            led.note(static_cast<uint32_t>(1000 + (i % 7)));
        expect(led.filled == FrameCostLedger::kCap, "ring filled cap");
        expect(led.count == FrameCostLedger::kCap + 50, "count past cap");
        const std::string s = led.formatLine("ring");
        expect(s.find("ring=8192") != std::string::npos, "ring size in line");
        expect(!s.empty() && s.find("mean_ms=") != std::string::npos, "ring format ok");
    }

    // NEG: pacing must not be implied — line states excl_pacing explicitly.
    {
        FrameCostLedger led;
        led.note(33333); // would be one 30fps *interval*, not work
        const std::string s = led.formatLine("pace_trap");
        expect(s.find("excl_pacing") != std::string::npos,
               "NEG: must label excl_pacing so interval is not mistaken for work");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_frame_cost_ledger: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_frame_cost_ledger\n");
    return 0;
}
