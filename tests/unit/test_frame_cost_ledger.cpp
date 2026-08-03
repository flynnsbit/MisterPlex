// Red-before-green: FrameCostLedger percentiles + split pipe/pixel/present.
//
// NEG: a ledger that reported paced interval (~33 ms @30) as "work" would
// pass a naive mean check but fail p99-vs-inject when samples are pure work.
// We inject known stage costs and require them to appear as distinct fields.
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

    {
        FrameCostLedger led;
        expect(led.empty(), "empty before note");
        const std::string s = led.formatLine("t0");
        expect(s.find("n=0") != std::string::npos, "empty format n=0");
    }

    // 95 frames: pipe=10ms present=5ms; 5 spikes present=40ms
    {
        FrameCostLedger led;
        for (int i = 0; i < 95; ++i)
            led.note(/*pipe*/ 10000, /*pixel*/ 500, /*present*/ 5000);
        for (int i = 0; i < 5; ++i)
            led.note(10000, 500, 40000);
        expect(led.count == 100, "count 100");
        expect(led.max_present_us == 40000, "max present spike");
        expect(led.max_work_us == 10000 + 500 + 40000, "max work = sum stages");
        const std::string s = led.formatLine("inject");
        expect(s.find("work_p50_ms=") != std::string::npos, "work_p50 field");
        expect(s.find("pipe_mean_ms=10") != std::string::npos ||
                   s.find("pipe_mean_ms=10.") != std::string::npos,
               "pipe mean ~10ms");
        expect(s.find("present_mean_ms=") != std::string::npos, "present mean field");
        expect(s.find("present_p99_ms=") != std::string::npos, "present p99 field");
        expect(s.find("pixel_mean_ms=") != std::string::npos, "pixel mean field");
        // NEG: must not be mean-only aggregate without stage split
        expect(s.find("present_mean_ms=") != std::string::npos &&
                   s.find("pipe_mean_ms=") != std::string::npos,
               "NEG: stages must be separate fields");
        expect(s.find("unit=pipe_pixel_present_excl_pacing") != std::string::npos,
               "unit tag split");
        expect(s.find("decode_note=in_ffmpeg_child_see_pipe") != std::string::npos,
               "decode attribution note");
        // Common-case work p50 ~ 15.5 ms (10+0.5+5)
        expect(s.find("work_p50_ms=15") != std::string::npos, "work p50 ~15.5ms");
    }

    {
        const uint32_t us[] = {1000, 2000, 3000, 4000};
        double p50 = 0, p99 = 0;
        expect(frameCostPctSmoke(us, 4, &p50, &p99), "smoke ok");
        expect(p50 >= 2.0 && p50 <= 3.0, "smoke p50 mid");
        expect(p99 >= 3.5 && p99 <= 4.0, "smoke p99 high");
    }

    {
        FrameCostLedger led;
        for (std::size_t i = 0; i < FrameCostLedger::kCap + 50; ++i)
            led.note(static_cast<uint32_t>(1000 + (i % 7)), 0, 100);
        expect(led.filled == FrameCostLedger::kCap, "ring filled cap");
        expect(led.count == FrameCostLedger::kCap + 50, "count past cap");
        const std::string s = led.formatLine("ring");
        expect(s.find("ring=8192") != std::string::npos, "ring size in line");
        expect(s.find("present_mean_ms=") != std::string::npos, "ring has present");
    }

    {
        FrameCostLedger led;
        led.note(33333, 0, 0); // would be one 30fps *interval* if mislabeled
        const std::string s = led.formatLine("pace_trap");
        expect(s.find("excl_pacing") != std::string::npos,
               "NEG: must label excl_pacing so interval is not mistaken for work");
    }

    // Backward-compat single-arg note puts all into pipe
    {
        FrameCostLedger led;
        led.note(12000u);
        const std::string s = led.formatLine("compat");
        expect(s.find("pipe_mean_ms=12") != std::string::npos, "compat note → pipe");
        expect(s.find("present_mean_ms=0.000") != std::string::npos, "compat present 0");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_frame_cost_ledger: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_frame_cost_ledger\n");
    return 0;
}
