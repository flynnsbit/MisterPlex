// Publish-interval ledger gate (w-geom judder root-cause).
//
// PRE-REGISTER (printed first) — parent device bands on ARRIVAL (pre-to-pre):
//   ARM_EXONERATED_FPGA_SIDE: sigma<4ms, p_in_band>=0.99, p_ge50_steady<0.03
//   ARM_LATE_MATCH_HOLD45: p_ge50 in [0.09,0.11]
// Discriminator (pre/post write stamps):
//   LATE_ARRIVAL: write flat on long arrival intervals
//   LATE_OBSERVATION: prior write_us large exactly when next arrival_iv > 50ms

#include "libmisterplex/publish_interval_ledger.hpp"
#include "libmisterplex/ddr_bank_release_select.hpp"

#include <algorithm>
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
    std::printf("  axis=arrival_pre (pre-to-pre); prior p_ge50 post-only UNSCORED\n");
    std::printf("  ARM_EXONERATED_FPGA_SIDE: sigma_ms<4 p_in_band>=0.99 p_ge50<0.03\n");
    std::printf("  ARM_LATE_MATCH_HOLD45: p_ge50 in [0.09,0.11]\n");
    std::printf("  disc LATE_ARRIVAL vs LATE_OBSERVATION via write_us on late ivs\n");
    std::printf("  ideal_ms=%.6f (frameRate=24.000)\n", 1000.0 / 24.0);
}

// Ideal 24fps; write_us flat 200us.
void fill_clean(misterplex::PublishIntervalLedger& L, int n) {
    L.reset();
    const int64_t step = 1000000 / 24;
    int64_t t = 1'000'000;
    for (int i = 0; i < n; ++i) {
        L.note(t, t + 200);
        t += step;
    }
}

// ~10% arrival intervals stretched; write flat → LATE_ARRIVAL.
void fill_late_arrival_10pct(misterplex::PublishIntervalLedger& L, int n) {
    L.reset();
    const int64_t ideal = 1000000 / 24;
    int64_t t = 1'000'000;
    L.note(t, t + 200);
    for (int i = 1; i < n; ++i) {
        int64_t step = ideal;
        if ((i % 10) == 0)
            step = 60000;
        else if ((i % 10) == 1)
            step = ideal - (60000 - ideal);
        if (step < 1000)
            step = 1000;
        t += step;
        L.note(t, t + 200);
    }
}

// Arrival (pre) cadence is ideal/clean; every 10th write blocks 15ms.
// post-only intervals would look late; pre-to-pre stays clean → LATE_OBSERVATION.
void fill_late_observation(misterplex::PublishIntervalLedger& L, int n) {
    L.reset();
    const int64_t ideal = 1000000 / 24;
    int64_t t = 1'000'000;
    for (int i = 0; i < n; ++i) {
        int64_t w = 200;
        if ((i % 10) == 9)
            w = 15000; // 15 ms inside write — observation inflates, arrival does not
        L.note(t, t + w);
        t += ideal;
    }
}

int check_stale_comment_fixed() {
    const char* path = "host/libmisterplex/ddr_bank_release_select.hpp";
    std::ifstream in(path);
    if (!in)
        in.open("../host/libmisterplex/ddr_bank_release_select.hpp");
    if (!in) {
        std::fprintf(stderr, "FAIL: cannot open ddr_bank_release_select.hpp\n");
        return 1;
    }
    std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    const bool stale =
        all.find("frames_done field is actually bank_vsync_count") != std::string::npos;
    EXPECT(!stale, "stale frames_done==bank_vsync_count claim removed");
    const bool fixed = all.find("real swap counter") != std::string::npos ||
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

    {
        PublishIntervalLedger L;
        fill_clean(L, 500);
        const auto s = L.summarize();
        std::printf("clean %s\n", L.formatSummaryLine("synthetic").c_str());
        std::printf("clean %s\n", L.formatDiscLine().c_str());
        EXPECT(s.intervals == 499, "clean interval count");
        EXPECT(std::fabs(s.mean_ms - (1000.0 / 24.0)) < 0.05, "clean mean ~41.667");
        EXPECT(std::fabs(s.median_ms - (1000.0 / 24.0)) < 0.05, "clean median ~41.667");
        EXPECT(std::fabs(s.trimmed_mean_ms - (1000.0 / 24.0)) < 0.05, "clean trimmed ~41.667");
        EXPECT(s.sigma_ms < 0.5, "clean sigma tiny");
        EXPECT(s.p_ge50 < 0.001, "clean no late");
        EXPECT(s.p_ge50_steady < 0.001, "clean steady no late");
        EXPECT(s.p_in_band > 0.99, "clean in band");
        EXPECT(std::string(s.verdict) == "ARM_EXONERATED_FPGA_SIDE",
               "clean verdict ARM_EXONERATED_FPGA_SIDE");
        EXPECT(std::fabs(s.mean_write_us - 200.0) < 1.0, "clean mean_write ~200us");
    }

    {
        PublishIntervalLedger L;
        fill_clean(L, 200);
        L.note(L.last_us + 5'000'000, L.last_us + 5'000'000 + 200);
        const auto s = L.summarize();
        std::printf("outlier %s\n", L.formatSummaryLine("synthetic").c_str());
        EXPECT(s.mean_ms > 50.0, "raw mean pulled up by outlier");
        EXPECT(std::fabs(s.median_ms - (1000.0 / 24.0)) < 1.0, "median resists outlier");
        EXPECT(std::fabs(s.trimmed_mean_ms - (1000.0 / 24.0)) < 2.0, "trimmed resists outlier");
    }

    {
        PublishIntervalLedger L;
        fill_late_arrival_10pct(L, 500);
        const auto s = L.summarize();
        std::printf("late_arr %s\n", L.formatSummaryLine("synthetic").c_str());
        std::printf("late_arr %s\n", L.formatDiscLine().c_str());
        std::printf("late_arr %s\n", L.formatHistLine().c_str());
        std::printf("late_arr %s\n", L.formatAutocorrLine().c_str());
        EXPECT(s.p_ge50 >= 0.08 && s.p_ge50 <= 0.12, "late_arr p_ge50 ~10%");
        EXPECT(s.p_lt25 > 0.05, "late_arr has catch-up shorts");
        EXPECT(L.lag1Autocorr() < 0.0, "late_arr catch-up lag1 acf negative");
        EXPECT(std::string(s.verdict) != "ARM_EXONERATED_FPGA_SIDE",
               "late_arr must not be EXONERATED");
        EXPECT(std::string(s.disc_verdict) == "LATE_ARRIVAL",
               "flat write + stretched pre => LATE_ARRIVAL");
        EXPECT(s.write_late_ratio < 1.5, "late_arr write ratio near 1");
    }

    {
        PublishIntervalLedger L;
        fill_late_observation(L, 500);
        const auto s = L.summarize();
        std::printf("late_obs %s\n", L.formatSummaryLine("synthetic").c_str());
        std::printf("late_obs %s\n", L.formatDiscLine().c_str());
        EXPECT(s.p_ge50 < 0.01, "late_obs arrival pre-to-pre stays clean");
        EXPECT(s.p_write_ge5ms >= 0.05, "late_obs has fat write tail p_write_ge5ms");
        EXPECT(s.write_max_us >= 10000, "late_obs write_max >= 10ms");
        EXPECT(std::string(s.disc_verdict) == "LATE_OBSERVATION",
               "clean arrival + fat write => LATE_OBSERVATION");
        EXPECT(std::string(s.verdict) == "ARM_EXONERATED_FPGA_SIDE",
               "late_obs arrival verdict still EXONERATED");
    }

    {
        PublishIntervalLedger L;
        fill_clean(L, 200);
        const double rho = L.lag1Autocorr();
        // Perfect constant series → den=0 → rho defined 0; allow tiny noise.
        EXPECT(std::fabs(rho) < 0.15 || !std::isfinite(rho), "clean lag1 acf ~0");
        std::printf("clean %s\n", L.formatAutocorrLine().c_str());
    }

    // M2 rolling window + 1 Hz fragment (mid-session pair windows).
    {
        PublishIntervalLedger L;
        fill_clean(L, 1500);
        const auto w = L.rollWindow(1440);
        EXPECT(w.n == 1440, "roll w60 n=1440 after 1500 clean notes");
        EXPECT(w.p_ge50 < 0.001, "roll clean p_ge50");
        EXPECT(std::string(w.disc) == "CLEAN", "roll clean disc");
        const std::string hz = L.formatHzFragment();
        std::printf("hz_clean %s\n", hz.c_str());
        EXPECT(hz.find("pub_iv_p_ge50_w60=") != std::string::npos, "hz has p_ge50_w60");
        EXPECT(hz.find("pub_iv_disc_w60=CLEAN") != std::string::npos, "hz disc CLEAN");
    }
    {
        PublishIntervalLedger L;
        fill_late_arrival_10pct(L, 1500);
        const auto w = L.rollWindow(1440);
        EXPECT(w.p_ge50 >= 0.05, "roll late_arr p_ge50 elevated");
        EXPECT(std::string(w.disc) == "LATE_ARRIVAL", "roll late_arr disc");
        const std::string hz = L.formatHzFragment();
        std::printf("hz_late %s\n", hz.c_str());
        EXPECT(hz.find("pub_iv_disc_w60=LATE_ARRIVAL") != std::string::npos, "hz LATE_ARRIVAL");
    }
    {
        // RED: empty ledger fragment is NO-DATA not fake zeros.
        PublishIntervalLedger L;
        const std::string hz = L.formatHzFragment();
        EXPECT(hz.find("pub_iv_n=0") != std::string::npos, "empty n=0");
        EXPECT(hz.find("NO-DATA") != std::string::npos, "empty NO-DATA");
        std::printf("hz_empty %s\n", hz.c_str());
    }

    std::printf("FACT tip RTL: frames_done++ on swap; PLXD packs frames_done_d2.\n");
    std::printf("FACT c5382bee packs bank_vsync_count into PLXD[63:48] — skip UNSCORED.\n");

    if (g_fails) {
        std::fprintf(stderr, "%d publish_interval fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_publish_interval_ledger\n");
    return 0;
}
