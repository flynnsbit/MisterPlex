// Red-before-green: frame ledger residual catches publish loss that drops + av_drift miss.
//
// Contrast (the test) — av_drift is shown ONLY to prove blindness, not as PASS:
//   - A/V pacer drops increment `drops` and are subtracted from residual.
//   - Failed DDR publish does NOT touch drops or av_drift_ms (drift uses frameIndex only).
//   - residual = frames - presents - drops rises on publish miss; drops stay clean.
//   - av_drift_ms staying 0 while residual=2 is the point: internal drift is not a
//     lip-sync or publish-health criterion (parent HDMI measure 2026-07-31).
#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/frame_ledger.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static std::string slurp(const std::string& path) {
    std::ifstream in(path);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

struct SimCounters {
    int64_t frames = 0;
    int64_t presents = 0;
    int64_t drops = 0;
    int64_t publish_misses = 0;
    int64_t av_drift_ms = 0;
};

static void simFrame(SimCounters* c, bool paceDrop, bool publishOk, int fpsNum = 24,
                     int fpsDen = 1) {
    ++c->frames;
    const int64_t contentMs = misterplex::frameContentMs(c->frames, fpsNum, fpsDen);
    c->av_drift_ms = misterplex::avDriftMs(/*audioMs=*/contentMs, /*frameMs=*/contentMs);
    if (paceDrop) {
        ++c->drops;
        return;
    }
    if (publishOk)
        ++c->presents;
    else
        ++c->publish_misses;
}

static void testPublishMissVsDropsAndDrift() {
    SimCounters c{};
    for (int i = 0; i < 97; ++i)
        simFrame(&c, /*paceDrop=*/false, /*publishOk=*/true);
    simFrame(&c, /*paceDrop=*/true, /*publishOk=*/true);
    simFrame(&c, /*paceDrop=*/false, /*publishOk=*/false);
    simFrame(&c, /*paceDrop=*/false, /*publishOk=*/false);

    CHECK(c.frames == 100);
    CHECK(c.presents == 97);
    CHECK(c.drops == 1);
    CHECK(c.publish_misses == 2);
    CHECK(c.av_drift_ms == 0);

    const auto live =
        misterplex::frameLedgerLiveOf(c.frames, c.presents, c.drops, c.publish_misses);
    CHECK(live.residual == 2);
    CHECK(misterplex::frameLedgerResidualExplainedByPublishMiss(live));
    CHECK(c.drops == 1);
    CHECK(c.av_drift_ms == 0);
    CHECK(live.residual != 0);

    const std::string frag = misterplex::frameLedgerTelemetryFragment(live);
    CHECK(live.measured);
    CHECK(frag.find("presents=97") != std::string::npos);
    CHECK(frag.find("drops=1") != std::string::npos);
    CHECK(frag.find("publish_misses=2") != std::string::npos);
    CHECK(frag.find("residual=2") != std::string::npos);
    CHECK(frag.find("UNKNOWN") == std::string::npos);

    SimCounters healthy{};
    for (int i = 0; i < 50; ++i)
        simFrame(&healthy, false, true);
    simFrame(&healthy, true, true);
    for (int i = 0; i < 49; ++i)
        simFrame(&healthy, false, true);
    const auto h = misterplex::frameLedgerLiveOf(healthy.frames, healthy.presents, healthy.drops,
                                                 healthy.publish_misses);
    CHECK(h.frames == 100);
    CHECK(h.presents == 99);
    CHECK(h.drops == 1);
    CHECK(h.publish_misses == 0);
    CHECK(h.residual == 0);
    CHECK(h.measured);
    CHECK(healthy.av_drift_ms == 0);
}

// residual=0 before any frames is NOT a health claim — must say UNKNOWN.
static void testUnmeasuredIsUnknownNotZero() {
    const auto empty = misterplex::frameLedgerLiveOf(0, 0, 0, 0);
    CHECK(!empty.measured);
    CHECK(empty.residual == 0); // arithmetic identity still holds
    const std::string frag = misterplex::frameLedgerTelemetryFragment(empty);
    CHECK(frag.find("residual=UNKNOWN") != std::string::npos);
    CHECK(frag.find("presents=UNKNOWN") != std::string::npos);
    CHECK(frag.find("drops=UNKNOWN") != std::string::npos);
    CHECK(frag.find("publish_misses=UNKNOWN") != std::string::npos);
    // Must not look like a clean soak (residual=0).
    CHECK(frag.find("residual=0") == std::string::npos);
    CHECK(!misterplex::frameLedgerResidualExplainedByPublishMiss(empty));

    // Rate fields: unusable wall must not collapse to 0.0.
    CHECK(misterplex::frameRateTelemetryField("vfps", 100, 0) == "vfps=UNKNOWN");
    CHECK(misterplex::frameRateTelemetryField("pfps_1s", 24, -1) == "pfps_1s=UNKNOWN");
    CHECK(misterplex::frameRateTelemetryField("vfps_1s", -1, 1000) == "vfps_1s=UNKNOWN");
    const std::string ok = misterplex::frameRateTelemetryField("pfps_1s", 24, 1000);
    CHECK(ok.find("pfps_1s=24.0") != std::string::npos);
}

static void testFileLedgerAcrossRestarts() {
    char dir_template[] = "build/frame_ledger_test_XXXXXX";
    const char* dir = ::mkdtemp(dir_template);
    CHECK(dir != nullptr);
    if (!dir)
        return;
    const std::string path = std::string(dir) + "/misterplexd.frame_ledger";
    misterplex::frameLedgerSetPathForTest(path);

    misterplex::frameLedgerProcessStart(0, 0, 0);
    misterplex::frameLedgerSessionEnd(1, 100, 98, 2, "eof", /*publishMisses=*/0);
    CHECK(misterplex::frameLedgerResidual(100, 98, 2) == 0);
    misterplex::frameLedgerProcessExit(0, "signal-g_stop_sig=15", 100, 98, 2, 196);

    misterplex::frameLedgerProcessStart(0, 0, 0);
    misterplex::frameLedgerSessionEnd(1, 50, 40, 5, "stop", /*publishMisses=*/5);
    CHECK(misterplex::frameLedgerResidual(50, 40, 5) == 5);
    misterplex::frameLedgerProcessExit(0, "signal-g_stop_sig=15", 50, 40, 5, 514);

    const std::string txt = slurp(path);
    CHECK(txt.find("event=process_start") != std::string::npos);
    CHECK(txt.find("event=session_end") != std::string::npos);
    CHECK(txt.find("event=process_exit") != std::string::npos);
    CHECK(txt.find("publish_misses=5") != std::string::npos);
    CHECK(txt.find("why=signal-g_stop_sig=15") != std::string::npos);
    int starts = 0;
    for (size_t i = 0; (i = txt.find("event=process_start", i)) != std::string::npos; ++i)
        ++starts;
    CHECK(starts == 2);

    misterplex::FrameLedgerTotals tot{};
    CHECK(misterplex::frameLedgerSumFile(path, &tot));
    CHECK(tot.processStarts == 2);
    CHECK(tot.processExits == 2);
    CHECK(tot.sessionEnds == 2);
    CHECK(tot.frames == 150);
    CHECK(tot.presents == 138);
    CHECK(tot.drops == 7);
    CHECK(tot.publish_misses == 5);
    CHECK(tot.residual == 5);
    CHECK(tot.residual == misterplex::frameLedgerResidual(tot.frames, tot.presents, tot.drops));

    misterplex::FrameLedgerTotals miss{};
    CHECK(!misterplex::frameLedgerSumFile(std::string(dir) + "/nope", &miss));
    CHECK(miss.sessionEnds == 0);
}

int main() {
    testPublishMissVsDropsAndDrift();
    testUnmeasuredIsUnknownNotZero();
    testFileLedgerAcrossRestarts();

    if (fails) {
        std::fprintf(stderr, "test_frame_ledger: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_frame_ledger: OK\n");
    return 0;
}
