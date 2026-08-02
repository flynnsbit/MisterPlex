// Red-before-green: starve locus (transport vs consumer vs unknown).
// Parent silicon fixtures (rk=9, same core/daemon/conf):
//   COLLAPSED supply_ratio 0.717  → must be starved (not ok)
//   HEALTHY   supply_ratio 0.993 / 0.977 → ok
// With full transport triad (recv_q=0, ffmpeg not pipe_write, daemon pipe_read)
//   → starved_transport rc=2
// Without probes → starved_unknown rc=4 (NOT forced transport)
// Session epoch change → SESSION_INVALID rc=79
#include "libmisterplex/supply_starve_locus.hpp"

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

    const double collapsed = 175.3 / 244.6; // 0.71668…
    const double healthy1 = 49.4 / 49.8;    // 0.99197…
    const double healthy2 = 162.6 / 166.4;  // 0.97716…
    CHECK(collapsed > 0.71 && collapsed < 0.72);
    CHECK(healthy1 > 0.99);
    CHECK(healthy2 > 0.97 && healthy2 < 0.98);
    CHECK(collapsed < 0.90 && healthy1 >= 0.90 && healthy2 >= 0.90);
    std::printf("PASS parent anchors collapsed=%.6f h1=%.6f h2=%.6f\n", collapsed, healthy1,
                healthy2);

    // GREEN healthy
    {
        StarveLocusInput in;
        in.supply_established = true;
        in.supply_ratio = healthy1;
        in.ok_min = 0.90;
        in.ok_min_src = "DEFAULT_ASSUMED";
        in.ledger_ok = true;
        in.frames = 1200;
        in.presents = 1187;
        in.drops = 13;
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::Ok);
        CHECK(starveLocusGateRc(r) == 0);
        CHECK(r.residual_ok && r.residual == 0);
        CHECK(std::strcmp(r.ok_min_src, "DEFAULT_ASSUMED") == 0);
        std::printf("PASS GREEN healthy1 rc=0 residual=%lld\n",
                    static_cast<long long>(r.residual));
    }
    {
        StarveLocusInput in;
        in.supply_established = true;
        in.supply_ratio = healthy2;
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::Ok);
        CHECK(starveLocusGateRc(r) == 0);
        std::printf("PASS GREEN healthy2 rc=0\n");
    }

    // RED collapsed without probes → starved_unknown (must NOT invent transport)
    {
        StarveLocusInput in;
        in.supply_established = true;
        in.supply_ratio = collapsed;
        in.ok_min = 0.90;
        in.ok_min_src = "DEFAULT_ASSUMED";
        in.ledger_ok = true;
        in.frames = 3000;
        in.presents = 1970;
        in.drops = 1030;
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::StarvedUnknown);
        CHECK(starveLocusGateRc(r) == 4);
        CHECK(r.residual == 0); // 3000-1970-1030
        CHECK(formatStarveLocusFragment(r).find("starved_unknown") != std::string::npos);
        CHECK(formatStarveLocusFragment(r).find("DEFAULT_ASSUMED") != std::string::npos);
        std::printf("PASS RED collapsed no-probes → unknown rc=4 residual=%lld\n",
                    static_cast<long long>(r.residual));
        if (starveLocusGateRc(r) != 4)
            return 4;
    }

    // RED collapsed + parent transport triad → starved_transport rc=2
    {
        StarveLocusInput in;
        in.supply_established = true;
        in.supply_ratio = collapsed;
        in.ffmpeg_in_pipe_write = ProbeTri::No;   // ZERO pipe_write
        in.daemon_in_pipe_read = ProbeTri::Yes;   // consumer wait
        in.recv_q_measured = true;
        in.recv_q = 0; // measured zero
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::StarvedTransport);
        CHECK(starveLocusGateRc(r) == 2);
        std::printf("PASS RED transport triad rc=2 reason=%s\n", r.reason);
        if (starveLocusGateRc(r) != 2)
            return 2;
    }

    // RED consumer: ffmpeg pipe_write
    {
        StarveLocusInput in;
        in.supply_established = true;
        in.supply_ratio = 0.72;
        in.ffmpeg_in_pipe_write = ProbeTri::Yes;
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::StarvedConsumer);
        CHECK(starveLocusGateRc(r) == 3);
        std::printf("PASS RED consumer pipe_write rc=3\n");
    }

    // RED consumer: recv_q > 0
    {
        StarveLocusInput in;
        in.supply_established = true;
        in.supply_ratio = 0.72;
        in.recv_q_measured = true;
        in.recv_q = 4096;
        in.ffmpeg_in_pipe_write = ProbeTri::No;
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::StarvedConsumer);
        CHECK(starveLocusGateRc(r) == 3);
        std::printf("PASS RED consumer recv_q rc=3\n");
    }

    // recv_q missing must not equal recv_q=0
    {
        StarveLocusInput in;
        in.supply_established = true;
        in.supply_ratio = 0.72;
        in.ffmpeg_in_pipe_write = ProbeTri::No;
        in.daemon_in_pipe_read = ProbeTri::Yes;
        // recv_q_measured=false
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::StarvedUnknown);
        CHECK(starveLocusGateRc(r) == 4);
        std::printf("PASS missing recv_q → unknown not transport\n");
    }

    // SESSION_INVALID
    {
        StarveLocusInput in;
        in.session_invalid = true;
        in.supply_established = true;
        in.supply_ratio = 0.99;
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::SessionInvalid);
        CHECK(starveLocusGateRc(r) == 79);
        std::printf("PASS SESSION_INVALID rc=79\n");
    }

    // NO-DATA
    {
        StarveLocusInput in;
        const auto r = computeStarveLocus(in);
        CHECK(r.cls == StarveLocusClass::NoData);
        CHECK(starveLocusGateRc(r) == 77);
        std::printf("PASS NO-DATA rc=77\n");
    }

    // Free ledger residual surfaces publish gap when drops don't explain
    {
        StarveLocusInput in;
        in.supply_established = true;
        in.supply_ratio = 0.99;
        in.ledger_ok = true;
        in.frames = 100;
        in.presents = 90;
        in.drops = 5; // residual 5 ≠ 0 — publish_miss or other
        in.publish_misses = 5;
        const auto r = computeStarveLocus(in);
        CHECK(r.residual == 5);
        CHECK(std::strcmp(r.drops_src, "av_pacer_only") == 0);
        std::printf("PASS residual free ledger frames-presents-drops=%lld\n",
                    static_cast<long long>(r.residual));
    }

    if (fails) {
        std::fprintf(stderr, "test_supply_starve_locus: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_supply_starve_locus: OK\n");
    return 0;
}
