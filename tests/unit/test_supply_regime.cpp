// Red-before-green: supply_regime separates path-starved vs back-pressure.
//
// Parent fixtures (2026-08-02 hardware):
//   path: supply_ratio~0.63, ~47 KB/s media, path ceiling ~108 KB/s with bulk pull
//   back-pressure regime is the OTHER unhealthy class: low supply + full pipe
//
// true rc: 0 ok | 2 path | 3 backpressure | 4 ambiguous | 77 NO-DATA
// Capture directly — never through a pipe.
#include "libmisterplex/supply_regime.hpp"
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

static misterplex::SupplyRegimeInput baseStarved() {
    misterplex::SupplyRegimeInput in;
    in.supply_interval_ok = true;
    in.supply_ratio = 0.63; // parent measured audio_s/wall_s class
    in.supply_starved = true;
    in.prev_pipe_valid = true;
    in.prev_pipe_bytes = 0;
    in.d_wall_s = 1.0;
    // 47 KB/s over 1 s
    in.pipe_bytes = 47 * 1024;
    in.capacity_ok = true;
    in.pipe_capacity_bytes = 2 * 1024 * 1024; // product default pipe
    in.fionread_ok = true;
    return in;
}

int main() {
    using namespace misterplex;

    // --- RED path: starved + empty pipe → starved_by_path rc=2 ---
    {
        auto in = baseStarved();
        in.pipe_avail_bytes = 0;
        in.pipe_avail_peak_bytes = 4096; // << 10% of 2 MiB
        const auto r = computeSupplyRegime(in);
        CHECK(r.established);
        CHECK(r.cls == SupplyRegimeClass::StarvedByPath);
        CHECK(r.pipe_rate_ok);
        CHECK(std::fabs(r.pipe_Bps - 47.0 * 1024.0) < 1.0);
        CHECK(r.fill_ok && r.fill_peak < kDefaultPipeFillEmptyMax);
        const int rc = supplyRegimeGateRc(r);
        CHECK(rc == 2);
        const std::string frag = formatSupplyRegimeFragment(r);
        CHECK(frag.find("supply_regime=starved_by_path") != std::string::npos);
        CHECK(frag.find("backpressure=no") != std::string::npos);
        CHECK(frag.find("pipe_bytes_scope=rawvideo_stdout_NOT_http") != std::string::npos);
        CHECK(frag.find("pipe_Bps_src=d_pipe_bytes/d_wall_s") != std::string::npos);
        std::printf("PASS RED path-starved rc=%d pipe_Bps=%.0f fill=%.4f\n", rc, r.pipe_Bps,
                    r.fill_peak);
        if (rc != 2)
            return 2;
    }

    // --- RED back-pressure: starved + full pipe → rc=3 ---
    {
        auto in = baseStarved();
        in.pipe_bytes = 47 * 1024; // still low delivery
        in.pipe_avail_peak_bytes = static_cast<int>(0.90 * in.pipe_capacity_bytes);
        const auto r = computeSupplyRegime(in);
        CHECK(r.cls == SupplyRegimeClass::StarvedByBackpressure);
        const int rc = supplyRegimeGateRc(r);
        CHECK(rc == 3);
        CHECK(formatSupplyRegimeFragment(r).find("backpressure=yes") != std::string::npos);
        std::printf("PASS RED backpressure rc=%d fill=%.3f\n", rc, r.fill_peak);
        if (rc != 3)
            return 3;
    }

    // --- GREEN healthy supply ---
    {
        SupplyRegimeInput in;
        in.supply_interval_ok = true;
        in.supply_ratio = 0.993;
        in.supply_starved = false;
        in.prev_pipe_valid = true;
        in.prev_pipe_bytes = 0;
        in.pipe_bytes = 449280; // ~1 frame/s would be low; use multi-frame healthy
        in.pipe_bytes = 24 * 449280;
        in.d_wall_s = 1.0;
        in.fionread_ok = true;
        in.pipe_avail_peak_bytes = 1000;
        in.capacity_ok = true;
        in.pipe_capacity_bytes = 2 * 1024 * 1024;
        const auto r = computeSupplyRegime(in);
        CHECK(r.cls == SupplyRegimeClass::Ok);
        CHECK(supplyRegimeGateRc(r) == 0);
        std::printf("PASS GREEN ok rc=0 pipe_Bps=%.0f\n", r.pipe_Bps);
    }

    // --- Ambiguous mid fill: hard rc=4, not 77 ---
    {
        auto in = baseStarved();
        in.pipe_avail_peak_bytes = static_cast<int>(0.40 * in.pipe_capacity_bytes);
        const auto r = computeSupplyRegime(in);
        CHECK(r.cls == SupplyRegimeClass::StarvedAmbiguous);
        CHECK(supplyRegimeGateRc(r) == 4);
        std::printf("PASS ambiguous starved rc=4\n");
    }

    // --- NO-DATA honesty: missing FIONREAD while starved → ambiguous not path ---
    {
        auto in = baseStarved();
        in.fionread_ok = false;
        in.pipe_avail_peak_bytes = -1;
        const auto r = computeSupplyRegime(in);
        CHECK(r.cls == SupplyRegimeClass::StarvedAmbiguous);
        CHECK(r.reason == std::string("starved_fill_NO-DATA") ||
              std::strcmp(r.reason, "starved_fill_NO-DATA") == 0);
        CHECK(formatSupplyRegimeFragment(r).find("pipe_fill_peak=NO-DATA") != std::string::npos);
        // Must not claim backpressure=no without a fill measurement
        CHECK(formatSupplyRegimeFragment(r).find("backpressure=no") == std::string::npos);
        std::printf("PASS fill NO-DATA does not invent empty\n");
    }

    // --- supply_ratio NO-DATA → regime 77 ---
    {
        SupplyRegimeInput in;
        in.supply_interval_ok = false;
        in.d_wall_s = 1.0;
        const auto r = computeSupplyRegime(in);
        CHECK(!r.established);
        CHECK(supplyRegimeGateRc(r) == 77);
        CHECK(formatSupplyRegimeFragment(r).find("supply_regime=NO-DATA") != std::string::npos);
        std::printf("PASS regime NO-DATA rc=77\n");
    }

    // --- Bidirectional: path then backpressure must not collapse ---
    {
        auto path = baseStarved();
        path.pipe_avail_peak_bytes = 0;
        auto bp = baseStarved();
        bp.pipe_avail_peak_bytes = bp.pipe_capacity_bytes - 1;
        CHECK(supplyRegimeGateRc(computeSupplyRegime(path)) == 2);
        CHECK(supplyRegimeGateRc(computeSupplyRegime(bp)) == 3);
        std::printf("PASS bidirectional path rc=2 vs bp rc=3\n");
    }

    // --- Parent path ceiling numbers are fixtures not measurements here ---
    {
        const double solo = 47e3;
        const double bulk = 60.6e3;
        const double ceil = solo + bulk;
        CHECK(std::fabs(ceil - 107.6e3) < 100.0);
        std::printf("PASS parent fixture arithmetic solo+bulk=%.0f\n", ceil);
    }

    // --- Trust note constant present ---
    CHECK(kSupplyRatioMinTrustWallS >= 3.0);
    CHECK(kDefaultSupplyRatioOkMin > 0.63); // 0.63 is starved under default ok_min

    // --- drops reset citation guard: this file documents correct lines ---
    // (compile-time documentation; media_player play-path stores at ~3000/3001)
    std::printf("NOTE drops/publishMisses reset = media_player play-path store(0) "
                ":3009/:3010 (NOT :2312/:2432 silence-scan)\n");

    if (fails) {
        std::fprintf(stderr, "test_supply_regime: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_supply_regime: OK (path vs backpressure red-before-green)\n");
    return 0;
}
