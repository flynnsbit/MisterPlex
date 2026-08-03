// Red-before-green: frame ledger residual catches publish loss that drops + av_drift miss.
//
// Contrast (the test):
//   - A/V pacer drops increment `drops` and are subtracted from residual.
//   - Failed DDR publish does NOT touch drops or av_drift_ms (drift uses frameIndex only).
//   - residual = frames - presents - drops rises on publish miss; drops stay clean.
#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/frame_ledger.hpp"
#include "libmisterplex/fpga_scanout_health.hpp"

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
    CHECK(frag.find("frames=100") != std::string::npos);
    CHECK(frag.find("presents=97") != std::string::npos);
    CHECK(frag.find("drops=1") != std::string::npos);
    CHECK(frag.find("publish_misses=2") != std::string::npos);
    CHECK(frag.find("residual=2") != std::string::npos);
    CHECK(frag.find("residual_eq=frames-presents-drops") != std::string::npos);
    CHECK(frag.find("residual_scope=supply_arm_only") != std::string::npos);
    CHECK(frag.find("fpga_obs=none") != std::string::npos);
    CHECK(frag.find("presents_src=arm_publish_ok") != std::string::npos);
    CHECK(frag.find("unaccounted=") == std::string::npos); // no duplicate alias
    CHECK(frag.find("tag=measured") != std::string::npos);
    CHECK(misterplex::sessionEpochString(1000, 3) == "1000.3");

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
    CHECK(healthy.av_drift_ms == 0);
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
    CHECK(txt.find("residual=5") != std::string::npos);
    CHECK(txt.find("residual_scope=supply_arm_only") != std::string::npos);
    CHECK(txt.find("fpga_obs=none") != std::string::npos);
    CHECK(txt.find("unaccounted=") == std::string::npos);
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

// Field defect (parent 2026-08-02): zero-frame session must NOT be natural_eof.
// RED twin: naive stop?stop:eof classifies 0/0 as natural_eof (applied-match=0).
// GREEN: classify → zero_frame_playback + ERROR line carries geom/bytes/vf.
static void testZeroFrameNotNaturalEof() {
    using namespace misterplex;
    int applied = 0;

    // RED twin: old product ternary.
    auto naive = [](bool stop, int64_t f, int64_t p) -> const char* {
        (void)f;
        (void)p;
        return stop ? "stop_or_seek" : "natural_eof";
    };
    CHECK(std::string(naive(false, 0, 0)) == "natural_eof"); // documents the defect
    ++applied;

    // GREEN matrix
    CHECK(std::string(frameLedgerClassifyEndReason(true, 0, 0)) ==
          kFrameLedgerReasonStopOrSeek);
    ++applied;
    CHECK(std::string(frameLedgerClassifyEndReason(true, 100, 100)) ==
          kFrameLedgerReasonStopOrSeek);
    ++applied;
    CHECK(std::string(frameLedgerClassifyEndReason(false, 0, 0)) ==
          kFrameLedgerReasonZeroFrame);
    ++applied;
    CHECK(std::string(frameLedgerClassifyEndReason(false, 1, 0)) ==
          kFrameLedgerReasonNaturalEof); // assembled but none presented
    ++applied;
    CHECK(std::string(frameLedgerClassifyEndReason(false, 0, 1)) ==
          kFrameLedgerReasonNaturalEof); // present without assemble count (edge)
    ++applied;
    CHECK(std::string(frameLedgerClassifyEndReason(false, 50, 50)) ==
          kFrameLedgerReasonNaturalEof);
    ++applied;

    CHECK(frameLedgerIsZeroFrameFailure(kFrameLedgerReasonZeroFrame));
    ++applied;
    CHECK(!frameLedgerIsZeroFrameFailure(kFrameLedgerReasonNaturalEof));
    ++applied;
    CHECK(!frameLedgerIsZeroFrameFailure(kFrameLedgerReasonStopOrSeek));
    ++applied;
    CHECK(!frameLedgerIsZeroFrameFailure(nullptr));
    ++applied;

    // ERROR line shape — one greppable line with all RCA fields.
    const std::string line = frameLedgerZeroFrameErrorLine(
        624, 350, /*producer=*/327600u, /*reader=*/449280u,
        "force_exact_crop_pad_unverified");
    CHECK(line.find("ERROR media: ZERO_FRAME_PLAYBACK") != std::string::npos);
    ++applied;
    CHECK(line.find("reason=zero_frame_playback") != std::string::npos);
    ++applied;
    CHECK(line.find("frames=0") != std::string::npos);
    ++applied;
    CHECK(line.find("presents=0") != std::string::npos);
    ++applied;
    CHECK(line.find("delivered_geom=624x350") != std::string::npos);
    ++applied;
    CHECK(line.find("producer_input_bytes=327600") != std::string::npos);
    ++applied;
    CHECK(line.find("reader_bytes=449280") != std::string::npos);
    ++applied;
    CHECK(line.find("vf_reason=force_exact_crop_pad_unverified") != std::string::npos);
    ++applied;
    CHECK(line.find("not_natural_eof") != std::string::npos);
    ++applied;
    CHECK(line.find("tag=measured") != std::string::npos);
    ++applied;

    // NO-DATA when delivery never measured (banner missing).
    const std::string nodata = frameLedgerZeroFrameErrorLine(0, 0, 0, 449280u, "");
    CHECK(nodata.find("delivered_geom=NO-DATA") != std::string::npos);
    ++applied;
    CHECK(nodata.find("vf_reason=NO-DATA") != std::string::npos);
    ++applied;

    // File ledger must persist the zero_frame_playback reason token.
    char dir_template[] = "build/frame_ledger_zf_XXXXXX";
    const char* dir = ::mkdtemp(dir_template);
    CHECK(dir != nullptr);
    ++applied;
    if (dir) {
        const std::string path = std::string(dir) + "/misterplexd.frame_ledger";
        frameLedgerSetPathForTest(path);
        frameLedgerProcessStart(0, 0, 0);
        const char* r = frameLedgerClassifyEndReason(false, 0, 0);
        frameLedgerSessionEnd(1, 0, 0, 0, r, 0);
        const std::string txt = slurp(path);
        CHECK(txt.find("event=session_end") != std::string::npos);
        ++applied;
        CHECK(txt.find("reason=zero_frame_playback") != std::string::npos);
        ++applied;
        CHECK(txt.find("reason=natural_eof") == std::string::npos);
        ++applied;
        CHECK(txt.find("frames=0") != std::string::npos);
        ++applied;
    }

    // applied-match count: a no-op mutation that deletes asserts cannot claim green.
    constexpr int kWantApplied = 28;
    CHECK(applied == kWantApplied);
    std::printf("ZERO_FRAME_REASON applied_match=%d want=%d\n", applied, kWantApplied);
}

// Parent 2026-08-02: presents advanced, HDMI idle, residual fpga_obs=none (static).
// RED: naive classify ignores scanout proof → natural_eof.
// GREEN: present_without_scanout + ERROR line + sample machine.
static void testPresentWithoutScanout() {
    using namespace misterplex;
    int applied = 0;

    // RED twin: old 3-arg classify treats healthy presents as natural_eof even
    // when scanout never proved live.
    CHECK(std::string(frameLedgerClassifyEndReason(false, 699, 699, /*noScanout=*/false)) ==
          kFrameLedgerReasonNaturalEof);
    ++applied;

    // GREEN: flag forces present_without_scanout
    CHECK(std::string(frameLedgerClassifyEndReason(false, 699, 699, true)) ==
          kFrameLedgerReasonPresentWithoutScanout);
    ++applied;
    CHECK(frameLedgerIsPresentWithoutScanout(kFrameLedgerReasonPresentWithoutScanout));
    ++applied;
    CHECK(!frameLedgerIsPresentWithoutScanout(kFrameLedgerReasonNaturalEof));
    ++applied;
    // stop still wins
    CHECK(std::string(frameLedgerClassifyEndReason(true, 699, 699, true)) ==
          kFrameLedgerReasonStopOrSeek);
    ++applied;
    // zero-frame still wins over scanout flag when presents==0
    CHECK(std::string(frameLedgerClassifyEndReason(false, 0, 0, true)) ==
          kFrameLedgerReasonZeroFrame);
    ++applied;

    // Sample machine: absent then presents advance without identity move → fail.
    FpgaScanoutHealth h{};
    FpgaScanoutSample a{};
    a.read_ok = false;
    a.presents = 0;
    CHECK(std::string(fpgaScanoutNoteSample(h, a)) == kFpgaObsPlxdAbsent);
    ++applied;
    a.presents = 10;
    CHECK(std::string(fpgaScanoutNoteSample(h, a)) == kFpgaObsPlxdAbsent);
    ++applied;
    a.presents = 30;
    CHECK(std::string(fpgaScanoutNoteSample(h, a)) == kFpgaObsPlxdAbsent);
    ++applied;
    CHECK(fpgaScanoutPresentWithoutProof(h));
    ++applied;
    CHECK(fpgaScanoutShouldReopen(h));
    ++applied;

    // Live path: identity moves → never present-without-proof.
    FpgaScanoutHealth live{};
    FpgaScanoutSample s{};
    s.read_ok = true;
    s.bank_sig = 0x1;
    s.presents = 0;
    CHECK(std::string(fpgaScanoutNoteSample(live, s)) == kFpgaObsPlxdBaseline);
    ++applied;
    s.bank_sig = 0x5;
    s.presents = 40;
    CHECK(std::string(fpgaScanoutNoteSample(live, s)) == kFpgaObsPlxdLive);
    ++applied;
    s.presents = 80;
    s.bank_sig = 0x5; // frozen after live once is OK — already proved
    (void)fpgaScanoutNoteSample(live, s);
    CHECK(live.live_samples >= 1);
    ++applied;
    CHECK(!fpgaScanoutPresentWithoutProof(live));
    ++applied;

    // Stale: readable, presents advance, identity frozen after baseline.
    FpgaScanoutHealth st{};
    s.read_ok = true;
    s.bank_sig = 0x2;
    s.presents = 5;
    CHECK(std::string(fpgaScanoutNoteSample(st, s)) == kFpgaObsPlxdBaseline);
    ++applied;
    s.presents = 40;
    CHECK(std::string(fpgaScanoutNoteSample(st, s)) == kFpgaObsPlxdStale);
    ++applied;
    s.presents = 50;
    (void)fpgaScanoutNoteSample(st, s);
    CHECK(fpgaScanoutPresentWithoutProof(st));
    ++applied;

    // ERROR line shape
    const std::string err = fpgaScanoutPresentWithoutProofErrorLine(st, 699, 699);
    CHECK(err.find("ERROR media: PRESENT_WITHOUT_SCANOUT") != std::string::npos);
    ++applied;
    CHECK(err.find("reason=present_without_scanout") != std::string::npos);
    ++applied;
    CHECK(err.find("presents_src=arm_publish_ok") != std::string::npos);
    ++applied;
    CHECK(err.find("fpga_obs=") != std::string::npos);
    ++applied;
    CHECK(err.find("tag=measured") != std::string::npos);
    ++applied;

    // Telemetry fragment must accept real obs (not only hardcoded none).
    FrameLedgerLive led = frameLedgerLiveOf(100, 100, 0, 0);
    const std::string frag = frameLedgerTelemetryFragment(led, kFpgaObsPlxdLive);
    CHECK(frag.find("fpga_obs=plxd_live") != std::string::npos);
    ++applied;
    CHECK(frag.find("presents_src=arm_publish_ok") != std::string::npos);
    ++applied;
    // Default still none (supply-only residual label).
    const std::string def = frameLedgerTelemetryFragment(led);
    CHECK(def.find("fpga_obs=none") != std::string::npos);
    ++applied;

    // File ledger persists present_without_scanout reason.
    char dir_template[] = "build/frame_ledger_pws_XXXXXX";
    const char* dir = ::mkdtemp(dir_template);
    CHECK(dir != nullptr);
    ++applied;
    if (dir) {
        const std::string path = std::string(dir) + "/misterplexd.frame_ledger";
        frameLedgerSetPathForTest(path);
        frameLedgerProcessStart(0, 0, 0);
        const char* r = frameLedgerClassifyEndReason(false, 699, 699, true);
        frameLedgerSessionEnd(1, 699, 699, 0, r, 0);
        const std::string txt = slurp(path);
        CHECK(txt.find("reason=present_without_scanout") != std::string::npos);
        ++applied;
        CHECK(txt.find("reason=natural_eof") == std::string::npos);
        ++applied;
    }

    constexpr int kWantApplied = 29;
    CHECK(applied == kWantApplied);
    std::printf("PRESENT_WITHOUT_SCANOUT applied_match=%d want=%d\n", applied, kWantApplied);
}

int main() {
    testPublishMissVsDropsAndDrift();
    testFileLedgerAcrossRestarts();
    testZeroFrameNotNaturalEof();
    testPresentWithoutScanout();

    if (fails) {
        std::fprintf(stderr, "test_frame_ledger: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_frame_ledger: OK\n");
    return 0;
}
