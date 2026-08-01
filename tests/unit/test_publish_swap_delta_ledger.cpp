// Publish swap-delta ledger: cadence hold + sigma gate (w-instr).
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
    std::printf("PRE-REGISTER swap-delta + cadence (parent 2026-08-01):\n");
    std::printf("  p_delta* = Δframes_done (swap/vsync pack) — NOT hold refreshes\n");
    std::printf("  p_hold_d* = round(iv_ms/T_vsync): d=2|3 OK, d=1 TOO_SHORT, d>=4 TOO_LONG\n");
    std::printf("  24@60 ideal alternation 2,3,2,3; mean_ms~41.667 does NOT imply smooth\n");
    std::printf("  p_ge50 scoreable only if sigma_ms < mean_ms; else UNSCORED_SIGMA_GE_MEAN\n");
    std::printf("  p_ge50 is publish iv>50ms fraction, NOT legitimate 3-refresh hold fraction\n");
    std::printf("  phase/vsync default tag=DEFAULT_ASSUMED until setVsyncHzMeasured\n");

    using misterplex::PublishSwapDeltaLedger;

    // Healthy free-gated: fd +1 each publish, ideal 41.667 ms interval
    // round(41.667/16.667)=3 always → all d=3, cad_alt=0 → CADENCE_IRREGULAR or OTHER
    // Real 3:2 needs alternating 33.3 and 50.0 ms publishes — separate test below.
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
        std::printf("healthy %s\n", L.formatCompatAliasLine().c_str());
        EXPECT(s.pairs == 299, "healthy pairs");
        EXPECT(s.p_delta0 < 0.001, "healthy no delta0");
        EXPECT(s.p_delta1 > 0.99, "healthy almost all delta1");
        EXPECT(std::string(s.fd_semantics) == "SWAP_COUNTER", "healthy fd_semantics");
        EXPECT(s.p_ge50_scoreable, "healthy p_ge50 scoreable");
        EXPECT(std::string(s.p_ge50_tag) == "measured", "healthy p_ge50_tag");
        EXPECT(std::string(s.cadence_verdict) == "CADENCE_METRONOME_OK" || std::string(s.cadence_verdict) == "CADENCE_OK_MILD", "healthy metronome cadence");
        EXPECT(std::string(s.interval_verdict) == "ARM_EXONERATED_FPGA_SIDE",
               "healthy interval exonerates ARM");
        EXPECT(std::string(s.skip_verdict) == "NO_ZERO_REFRESH_SKIP", "healthy no skip");
        EXPECT(std::string(s.vsync_tag) == "DEFAULT_ASSUMED", "default vsync tag");
    }

    // Clean 3:2 publish cadence: alternate 2 and 3 refreshes (33.333 / 50.000 ms)
    {
        PublishSwapDeltaLedger L;
        L.setSrcFpsMeasured(24.0);
        L.setVsyncHzDefaultAssumed(60.0);
        int64_t t = 1'000'000;
        uint16_t fd = 0;
        // 2*16.666ms = 33333us, 3*16.666ms = 50000us
        for (int i = 0; i < 400; ++i) {
            L.note(t, fd, 0, 1, 0);
            t += (i % 2 == 0) ? 33333 : 50000;
            fd = static_cast<uint16_t>(fd + 1);
        }
        const auto s = L.summarize();
        std::printf("cadence32 %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.p_hold_d1 < 0.01, "32 clean no d1");
        EXPECT(s.p_hold_d2 > 0.4 && s.p_hold_d2 < 0.6, "32 ~half d2");
        EXPECT(s.p_hold_d3 > 0.4 && s.p_hold_d3 < 0.6, "32 ~half d3");
        EXPECT(s.cad_alt_frac > 0.9, "32 high alternation");
        EXPECT(std::string(s.cadence_verdict) == "CADENCE_32_CLEAN", "32 clean verdict");
        // mean ~41.67, low sigma, few >50 exactly at 50.0 — p_ge50 uses >50 so 50.0 not counted
        EXPECT(s.p_ge50_scoreable, "32 p_ge50 scoreable");
        EXPECT(std::fabs(s.mean_ms - 41.666) < 1.0, "32 mean near ideal");
    }

    // HITCHY: ~3.5% single-refresh holds (parent class ~one hitch/sec @24fps)
    {
        PublishSwapDeltaLedger L;
        int64_t t = 1'000'000;
        uint16_t fd = 0;
        for (int i = 0; i < 400; ++i) {
            L.note(t, fd, 0, 1, 0);
            // every 30th interval is 1 refresh; else alternate 2/3
            if (i > 0 && (i % 30) == 0)
                t += 16667;
            else
                t += (i % 2 == 0) ? 33333 : 50000;
            fd = static_cast<uint16_t>(fd + 1);
        }
        const auto s = L.summarize();
        std::printf("hitchy %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.p_hold_d1 >= 0.02, "hitchy d1 elevated");
        EXPECT(std::string(s.cadence_verdict) == "HITCHY_D1", "hitchy verdict");
        // mean still near ideal possible
        EXPECT(std::fabs(s.mean_ms - 41.667) < 5.0, "hitchy mean still near ideal");
    }

    // IRREGULAR: only d=2 and d=3 but scrambled (runs of 2s and 3s), avg ok
    {
        PublishSwapDeltaLedger L;
        int64_t t = 1'000'000;
        uint16_t fd = 0;
        for (int i = 0; i < 400; ++i) {
            L.note(t, fd, 0, 1, 0);
            // blocks of 5×2 then 5×3 → low alternation
            const int block = (i / 5) % 2;
            t += (block == 0) ? 33333 : 50000;
            fd = static_cast<uint16_t>(fd + 1);
        }
        const auto s = L.summarize();
        std::printf("irregular %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.p_hold_d1 < 0.01, "irregular no d1");
        EXPECT(s.cad_alt_frac < 0.55, "irregular low alt");
        EXPECT(std::string(s.cadence_verdict) == "CADENCE_IRREGULAR", "irregular verdict");
    }

    // T2 RED: sigma >= mean → p_ge50 UNSCORED (parent stop_or_seek class)
    {
        PublishSwapDeltaLedger L;
        int64_t t = 1'000'000;
        uint16_t fd = 0;
        // Mostly ~42ms with rare huge gaps → sigma > mean
        for (int i = 0; i < 200; ++i) {
            L.note(t, fd, 0, 1, 0);
            if ((i % 20) == 19)
                t += 500000; // 500 ms outlier
            else
                t += 41667;
            fd = static_cast<uint16_t>(fd + 1);
        }
        const auto s = L.summarize();
        std::printf("sigma_ge_mean %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.sigma_ms >= s.mean_ms, "sigma>=mean setup");
        EXPECT(!s.p_ge50_scoreable, "p_ge50 not scoreable");
        EXPECT(std::string(s.p_ge50_tag) == "UNSCORED_SIGMA_GE_MEAN", "sigma gate tag");
        EXPECT(std::string(s.interval_verdict) == "UNSCORED_SIGMA_GE_MEAN", "sigma gate verdict");
        // raw fraction still computed (for forensics) but not a score
        EXPECT(s.p_ge50 > 0.0, "raw p_ge50 still emitted");
    }

    // T2 GREEN companion: same p_ge50-ish band but sigma << mean → scoreable
    {
        PublishSwapDeltaLedger L;
        int64_t t = 1'000'000;
        uint16_t fd = 0;
        // ~14% intervals at 55ms, rest 40ms → p_ge50~0.14, sigma modest
        for (int i = 0; i < 500; ++i) {
            L.note(t, fd, 0, 1, 0);
            t += ((i % 7) == 0) ? 55000 : 40000;
            fd = static_cast<uint16_t>(fd + 1);
        }
        const auto s = L.summarize();
        std::printf("sigma_ok_late %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.sigma_ms < s.mean_ms, "sigma<mean");
        EXPECT(s.p_ge50_scoreable, "scoreable when sigma ok");
        EXPECT(std::string(s.p_ge50_tag) == "measured", "measured tag");
        EXPECT(s.p_ge50 > 0.11, "elevated p_ge50");
        EXPECT(std::string(s.interval_verdict) == "ARM_LATE_OR_BIMODAL", "late verdict");
    }

    // Overwrite class on real swap counter
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
        if (s.p_delta1 >= 0.5)
            EXPECT(std::string(s.skip_verdict) == "ZERO_REFRESH_SKIPS_PRESENT",
                   "overwrite skip when swap-counter premise holds");
        else
            EXPECT(std::string(s.skip_verdict) == "UNSCORED",
                   "borderline p_d1 → UNSCORED skip");
    }

    // c5382bee-class: Δfd ~3 → skip MUST be UNSCORED
    {
        PublishSwapDeltaLedger L;
        const int64_t step = 50000;
        int64_t t = 1'000'000;
        uint16_t fd = 0;
        for (int i = 0; i < 300; ++i) {
            L.note(t, fd, 0, 1, 0);
            t += step;
            fd = static_cast<uint16_t>(fd + 3);
        }
        const auto s = L.summarize();
        std::printf("vsync_packed %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.p_delta_ge2 > 0.9, "vsync_packed mostly dge2");
        EXPECT(s.p_delta1 < 0.1, "vsync_packed rare d1");
        EXPECT(std::string(s.skip_verdict) == "UNSCORED",
               "vsync_packed never claims NO_ZERO_REFRESH_SKIP");
        EXPECT(std::string(s.fd_semantics) == "LIKELY_VSYNC_PACKED",
               "classify LIKELY_VSYNC_PACKED");
        EXPECT(s.mean_delta > 2.5 && s.mean_delta < 3.5, "mean_delta ~3");
    }

    // uint16 wrap
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
