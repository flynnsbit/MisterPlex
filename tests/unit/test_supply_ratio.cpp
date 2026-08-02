// Red-before-green gate for supply_ratio (stream starvation metric).
//
// Parent-measured fixtures (exact numbers from RCA):
//   STARVED: audio_s=33.42 wall_s=72.58  → ratio 0.460
//   HEALTHY: audio_s=69.94 wall_s=70.43  → ratio 0.993
//
// true rc captured by the test runner directly (no pipes on the gate itself).
//   rc=0 ok | rc=2 starved | rc=77 NO-DATA
//
// No device. Host-pure.
#include "libmisterplex/supply_ratio.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

static int fails = 0;
#define CHECK(c)                                                                               \
    do {                                                                                       \
        if (!(c)) {                                                                            \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                   \
            ++fails;                                                                           \
        }                                                                                      \
    } while (0)

int main() {
    using namespace misterplex;

    // --- Parent anchors as pure division (document the RCA numbers) ---
    const double starved_a = 33.42;
    const double starved_w = 72.58;
    const double healthy_a = 69.94;
    const double healthy_w = 70.43;
    const double starved_r = starved_a / starved_w;
    const double healthy_r = healthy_a / healthy_w;
    CHECK(starved_r > 0.45 && starved_r < 0.47);
    CHECK(healthy_r > 0.99 && healthy_r < 1.00);
    std::printf("PASS parent anchors starved=%.6f healthy=%.6f\n", starved_r, healthy_r);

    // --- RED: starved cumulative-as-interval (single long window) must FAIL rc=2 ---
    {
        // Model one interval spanning the whole starved session (prev at origin).
        const auto r = computeSupplyRatio(/*prev_valid=*/true, /*prev_a=*/0.0, /*prev_w=*/0.0,
                                          starved_a, starved_w, /*audio*/ true, /*paused*/ false);
        CHECK(r.interval_established);
        CHECK(r.cls == SupplyRatioClass::Starved);
        CHECK(std::fabs(r.interval_ratio - starved_r) < 1e-9);
        const int rc = supplyRatioGateRc(r);
        CHECK(rc == 2);
        const std::string frag = formatSupplyRatioFragment(r);
        CHECK(frag.find("supply_ratio=0.460") != std::string::npos ||
              frag.find("supply_ratio=0.46") != std::string::npos);
        CHECK(frag.find("src=d_audio_s/d_wall_s") != std::string::npos);
        CHECK(frag.find("supply_ratio_class=starved") != std::string::npos);
        CHECK(frag.find("supply_ratio_ok_min=") != std::string::npos);
        CHECK(frag.find("av_drift_ms") == std::string::npos);
        std::printf("PASS RED starved gate rc=%d ratio=%.6f frag_has_class\n", rc,
                    r.interval_ratio);
        if (rc != 2) {
            std::fprintf(stderr, "RED gate must return 2 on starved, got %d\n", rc);
            return 2;
        }
    }

    // --- GREEN: healthy must PASS rc=0 ---
    {
        const auto r = computeSupplyRatio(true, 0.0, 0.0, healthy_a, healthy_w, true, false);
        CHECK(r.interval_established);
        CHECK(r.cls == SupplyRatioClass::Ok);
        CHECK(std::fabs(r.interval_ratio - healthy_r) < 1e-9);
        const int rc = supplyRatioGateRc(r);
        CHECK(rc == 0);
        const std::string frag = formatSupplyRatioFragment(r);
        CHECK(frag.find("supply_ratio_class=ok") != std::string::npos);
        CHECK(frag.find("src=d_audio_s/d_wall_s") != std::string::npos);
        std::printf("PASS GREEN healthy gate rc=%d ratio=%.6f\n", rc, r.interval_ratio);
        if (rc != 0) {
            std::fprintf(stderr, "GREEN gate must return 0 on healthy, got %d\n", rc);
            return 1;
        }
    }

    // --- Both directions in one breath (interval stepping) ---
    {
        // Second 1s of a healthy stream: Δa≈0.993, Δw=1.0
        const auto ok = computeSupplyRatio(true, 10.0, 10.0, 10.0 + 0.993, 11.0, true, false);
        CHECK(supplyRatioGateRc(ok) == 0);
        // Starved 1s: Δa=0.46, Δw=1.0
        const auto st = computeSupplyRatio(true, 10.0, 10.0, 10.46, 11.0, true, false);
        CHECK(supplyRatioGateRc(st) == 2);
        std::printf("PASS bidirectional interval ok_rc=0 starved_rc=2\n");
    }

    // --- NO-DATA honesty: never 0.0, never defect ---
    {
        auto r = computeSupplyRatio(false, 0, 0, 1.0, 1.0, true, false);
        CHECK(!r.interval_established);
        CHECK(supplyRatioGateRc(r) == 77);
        CHECK(formatSupplyRatioFragment(r).find("supply_ratio=NO-DATA") != std::string::npos);
        CHECK(formatSupplyRatioFragment(r).find("supply_ratio=0.000") == std::string::npos);

        r = computeSupplyRatio(true, 0, 0, 5.0, 10.0, false, false);
        CHECK(r.reason == std::string("audio_off") || std::strcmp(r.reason, "audio_off") == 0);
        CHECK(supplyRatioGateRc(r) == 77);

        r = computeSupplyRatio(true, 0, 0, 5.0, 10.0, true, true);
        CHECK(std::strcmp(r.reason, "paused") == 0);
        CHECK(supplyRatioGateRc(r) == 77);

        r = computeSupplyRatio(true, 5.0, 10.0, 5.0, 10.1, true, false); // d_wall too small
        CHECK(std::strcmp(r.reason, "d_wall_le0") == 0);
        CHECK(supplyRatioGateRc(r) == 77);

        r = computeSupplyRatio(true, 10.0, 10.0, 5.0, 12.0, true, false); // reset
        CHECK(std::strcmp(r.reason, "d_audio_reset_or_invalid") == 0);
        CHECK(supplyRatioGateRc(r) == 77);
        std::printf("PASS NO-DATA paths rc=77 never 0.0\n");
    }

    // --- Cumulative labelled separately; class from INTERVAL only ---
    {
        // First sample: cum may establish after min wall, interval still NO-DATA
        const auto r = computeSupplyRatio(false, 0, 0, starved_a, starved_w, true, false);
        CHECK(!r.interval_established);
        CHECK(r.cumulative_established);
        CHECK(std::fabs(r.cumulative_ratio - starved_r) < 1e-9);
        CHECK(supplyRatioGateRc(r) == 77); // must NOT starve-verdict without interval
        const std::string frag = formatSupplyRatioFragment(r);
        CHECK(frag.find("supply_ratio=NO-DATA") != std::string::npos);
        CHECK(frag.find("supply_ratio_cum=0.460") != std::string::npos ||
              frag.find("supply_ratio_cum=0.46") != std::string::npos);
        CHECK(frag.find("supply_ratio_cum_src=audio_s/wall_s") != std::string::npos);
        std::printf("PASS cum labelled; gate stays 77 without interval\n");
    }

    // --- Threshold override is caller_supplied ---
    {
        // 0.993 is ok at 0.90; starved at ok_min=0.995
        const auto r = computeSupplyRatio(true, 0, 0, healthy_a, healthy_w, true, false, 0.995,
                                          "caller_supplied");
        CHECK(r.cls == SupplyRatioClass::Starved);
        CHECK(std::strcmp(r.ok_min_src, "caller_supplied") == 0);
        CHECK(supplyRatioGateRc(r) == 2);
        std::printf("PASS configurable ok_min\n");
    }

    // --- clock_master / desync_risk fragments: no av-lock, scope pinned ---
    {
        const std::string c = formatClockMasterFragment(true);
        CHECK(c.find("clock_master=audio") != std::string::npos);
        CHECK(c.find("clock=av-lock") == std::string::npos);
        CHECK(c.find("REMOVED_was_hardcoded") != std::string::npos);
        const std::string d = formatDesyncRiskFragment(false);
        CHECK(d.find("desync_risk=0") != std::string::npos);
        CHECK(d.find("raw_pipe_geometry_NOT_av_supply") != std::string::npos);
        std::printf("PASS clock_master + desync_risk scope\n");
    }

    // --- Default threshold is between the two clusters ---
    CHECK(kDefaultSupplyRatioOkMin > starved_r);
    CHECK(kDefaultSupplyRatioOkMin < healthy_r);

    if (fails) {
        std::fprintf(stderr, "test_supply_ratio: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_supply_ratio: OK (red-before-green proven)\n");
    return 0;
}
