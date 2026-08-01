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
    std::printf("PRE-REGISTER publish-interval device bands (parent soak):\n");
    std::printf("  ARM_CLEAN: sigma_ms<4 p_in_band>=0.99 p_ge50<0.03\n");
    std::printf("  ARM_LATE_MATCH_HOLD45: p_ge50 in [0.09,0.11] (~4/5-hold fraction)\n");
    std::printf("  p_ge50<0.03 => late-publish hypothesis FALSIFIED\n");
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
        EXPECT(s.sigma_ms < 0.5, "clean sigma tiny");
        EXPECT(s.p_ge50 < 0.001, "clean no late");
        EXPECT(s.p_in_band > 0.99, "clean in band");
        EXPECT(std::string(s.verdict) == "ARM_CLEAN", "clean verdict ARM_CLEAN");
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
        EXPECT(std::string(s.verdict) != "ARM_CLEAN", "late10 must not be CLEAN");
    }

    // Clean acf ~0
    {
        PublishIntervalLedger L;
        fill_clean(L, 200);
        const double rho = L.lag1Autocorr();
        std::printf("clean %s\n", L.formatAutocorrLine().c_str());
        EXPECT(std::fabs(rho) < 0.05, "clean lag1 acf ~0");
    }

    // frames_done semantics note (documentation lock for fabric tool death)
    std::printf("FACT frames_done increments only on swap (vsync&&pending&&ready); "
                "Delta frames_done between publishes is typically 1 and carries "
                "ZERO hold-length info. Fabric hold-via-fd-edges is INVALID.\n");
    std::printf("FACT vsync_toggle / bank_vsync_count not ARM-readable via PLXD "
                "(reserved [47:36]=0); would need RBF to pack.\n");

    if (g_fails) {
        std::fprintf(stderr, "%d publish_interval fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_publish_interval_ledger\n");
    return 0;
}
