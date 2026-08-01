// Publish-interval ledger gate (w-geom judder root-cause).
//
// PRE-REGISTER (printed first) — parent device bands:
//   ARM_CLEAN: sigma<4ms, p_in_band>=0.99, p_ge50<0.03
//   ARM_LATE_MATCH_HOLD45: p_ge50 in [0.09,0.11]
//   below ~3% ge50 → late-publish hypothesis DEAD
//
// Also locks: frames_done is SWAP count (comment/source), not vsync.

#include "libmisterplex/publish_interval_ledger.hpp"
#include "libmisterplex/ddr_bank_release_select.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
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

void pre_register() {
    std::printf("PRE-REGISTER publish-interval device bands (parent soak ERROR 21):\n");
    std::printf("  ARM_EXONERATED_FPGA_SIDE: sigma_ms<4 p_in_band>=0.99 p_ge50<0.03\n");
    std::printf("    => ARM clean; redirect search to CDC/DDR-completion (NOT dead end)\n");
    std::printf("  ARM_LATE_MATCH_HOLD45: p_ge50 in [0.09,0.11] (~4/5-hold fraction)\n");
    std::printf("  ideal_ms=%.6f (frameRate=24.000, not 23.976)\n", 1000.0 / 24.0);
}

// Ideal 24.000: every interval exactly 1000/24 ms in us.
void fill_clean(misterplex::PublishIntervalLedger& L, int n) {
    L.reset();
    const int64_t step = 1000000 / 24; // 41666 us
    int64_t t = 1'000'000;
    for (int i = 0; i < n; ++i) {
        L.note(t);
        t += step;
    }
}

// ~10% intervals stretched to 60ms, next shortened (catch-up).
void fill_late_10pct(misterplex::PublishIntervalLedger& L, int n) {
    L.reset();
    const int64_t ideal = 1000000 / 24;
    int64_t t = 1'000'000;
    L.note(t);
    for (int i = 1; i < n; ++i) {
        int64_t step = ideal;
        if ((i % 10) == 0)
            step = 60000; // >50ms late
        else if ((i % 10) == 1)
            step = ideal - (60000 - ideal); // catch-up short
        if (step < 1000)
            step = 1000;
        t += step;
        L.note(t);
    }
}

int check_stale_comment_fixed() {
    // File must NOT still claim product frames_done IS bank_vsync_count.
    const char* path = "host/libmisterplex/ddr_bank_release_select.hpp";
    std::ifstream in(path);
    if (!in) {
        // try from build cwd parent
        in.open("../host/libmisterplex/ddr_bank_release_select.hpp");
    }
    if (!in) {
        std::fprintf(stderr, "FAIL: cannot open ddr_bank_release_select.hpp\n");
        return 1;
    }
    std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    const bool stale =
        all.find("frames_done field is actually bank_vsync_count") != std::string::npos;
    EXPECT(!stale, "stale frames_done==bank_vsync_count claim removed");
    const bool fixed =
        all.find("real swap counter") != std::string::npos ||
        all.find("NOT bank_vsync_count") != std::string::npos;
    EXPECT(fixed, "replacement text documents product swap counter");
    std::printf("PASS stale_comment_fixed\n");
    return g_fails ? 1 : 0;
}

} // namespace

int main() {
    pre_register();

    if (check_stale_comment_fixed() != 0)
        return 1;

    using misterplex::PublishIntervalLedger;

    // Clean
    {
        PublishIntervalLedger L;
        fill_clean(L, 500);
        const auto s = L.summarize();
        std::printf("clean %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.intervals == 499, "clean interval count");
        EXPECT(std::fabs(s.mean_ms - (1000.0 / 24.0)) < 0.05, "clean mean ~41.667");
        EXPECT(std::fabs(s.median_ms - (1000.0 / 24.0)) < 0.05, "clean median ~41.667");
        EXPECT(std::fabs(s.trimmed_mean_ms - (1000.0 / 24.0)) < 0.05, "clean trimmed ~41.667");
        EXPECT(s.sigma_ms < 0.5, "clean sigma tiny");
        EXPECT(s.p_ge50 < 0.001, "clean no late");
        EXPECT(s.p_ge50_steady < 0.001, "clean steady no late");
        EXPECT(s.p_in_band > 0.99, "clean in band");
        EXPECT(std::string(s.verdict) == "ARM_EXONERATED_FPGA_SIDE",
               "clean verdict ARM_EXONERATED_FPGA_SIDE (ERROR 21)");
    }

    // Outlier-skewed raw mean still has stable median/trimmed
    {
        PublishIntervalLedger L;
        fill_clean(L, 200);
        // Inject one huge gap (session tear)
        L.note(L.last_us + 5'000'000);
        const auto s = L.summarize();
        std::printf("outlier %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.mean_ms > 50.0, "raw mean pulled up by outlier");
        EXPECT(std::fabs(s.median_ms - (1000.0 / 24.0)) < 1.0, "median resists outlier");
        EXPECT(std::fabs(s.trimmed_mean_ms - (1000.0 / 24.0)) < 2.0, "trimmed resists outlier");
    }

    // Late 10%
    {
        PublishIntervalLedger L;
        fill_late_10pct(L, 500);
        const auto s = L.summarize();
        std::printf("late10 %s\n", L.formatSummaryLine("synthetic").c_str());
        std::printf("late10 %s\n", L.formatHistLine().c_str());
        std::printf("late10 %s\n", L.formatAutocorrLine().c_str());
        std::printf("late10 %s\n", L.formatCorrLine().c_str());
        EXPECT(s.p_ge50 >= 0.08 && s.p_ge50 <= 0.12, "late10 p_ge50 ~10%");
        EXPECT(s.p_lt25 > 0.05, "late10 has catch-up shorts");
        const auto c = L.shortIntervalCorrelation(25.0);
        EXPECT(c.short_n > 0, "corr has shorts");
        // Catch-up model: long then short → lag1 autocorr negative
        const double rho = L.lag1Autocorr();
        EXPECT(rho < 0.0, "late10 catch-up model lag1 acf negative");
        // After a stretch, catch-up is short → short_then often follows late in our model
        EXPECT(std::string(s.verdict) == "ARM_LATE_MATCH_HOLD45" ||
                   std::string(s.verdict) == "ARM_LATE_OR_BIMODAL" ||
                   std::string(s.verdict) == "ARM_LATE_MILD",
               "late10 not ARM_CLEAN");
        EXPECT(std::string(s.verdict) != "ARM_EXONERATED_FPGA_SIDE",
               "late10 must not be EXONERATED");
    }

    // Clean acf ~0
    {
        PublishIntervalLedger L;
        fill_clean(L, 200);
        const double rho = L.lag1Autocorr();
        std::printf("clean %s\n", L.formatAutocorrLine().c_str());
        EXPECT(std::fabs(rho) < 0.05, "clean lag1 acf ~0");
    }

    std::printf("FACT tip RTL: internal frames_done++ only on swap; PLXD packs "
                "frames_done_d2. DEPLOYED c5382bee packs bank_vsync_count into "
                "PLXD[63:48] (HISTORICAL FAULT live) — see test_c5382bee_frames_done_pack.\n");
    std::printf("FACT on c5382bee, ΔPLXD_fd tracks vsyncs/interval (~3 @50ms), NOT swaps; "
                "skip_verdict must be UNSCORED when p_d1<0.5.\n");

    if (g_fails) {
        std::fprintf(stderr, "%d publish_interval fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_publish_interval_ledger\n");
    return 0;
}
