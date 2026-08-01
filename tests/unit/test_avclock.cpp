// Unit tests for the A/V master-clock math (host/libmisterplex/av_clock.hpp).
//
// This is the math that shipped wrong: the present loop paced frames with
// `frameIndex * 1000 / fps` and an integer fps, so 23.976 fps content was scheduled
// at 24.000 and video crept ahead of audio by ~1 ms/s — ~234 ms by 3:54 and ~5.5 s
// by the end of a 91 minute episode.
#include "libmisterplex/av_clock.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // --- exact rational schedule ---
    CHECK(frameContentMs(0, 24, 1) == 0);
    CHECK(frameContentMs(24, 24, 1) == 1000);
    CHECK(frameContentMs(24000, 24000, 1001) == 1001000);

    // 131 400 frames ≈ 91 min at 23.976. Rational int64 math must stay sub-ms against
    // the exact real-valued schedule over a whole episode.
    {
        const int64_t n = 131400;
        const double exact = static_cast<double>(n) * 1000.0 * 1001.0 / 24000.0;
        const int64_t got = frameContentMs(n, 24000, 1001);
        CHECK(std::fabs(static_cast<double>(got) - exact) < 1.0);

        // The bug being fixed: the old integer-fps schedule is ~5.5 s off by then.
        const int64_t buggy = (n * 1000LL) / 24;
        CHECK(exact - static_cast<double>(buggy) > 5000.0);
    }

    // Bad rates fall back to the 24/1 default rather than dividing by zero.
    CHECK(frameContentMs(24, 0, 1) == frameContentMs(24, kDefaultFpsNum, kDefaultFpsDen));
    CHECK(frameContentMs(24, 24, 0) == frameContentMs(24, kDefaultFpsNum, kDefaultFpsDen));

    // --- audio master clock (48 kHz stereo s16le = 192 000 B/s) ---
    CHECK(audioClockMs(0) == 0);
    CHECK(audioClockMs(192000) == 1000);
    CHECK(audioClockMs(192000LL * 3600) == 3600000);

    // --- drift polarity ---
    // drift > 0 means the master clock is past this frame's content time → video behind.
    CHECK(avDriftMs(1000, 900) == 100);
    CHECK(avDriftMs(900, 1000) == -100);

    // --- resync decisions ---
    const int64_t lead = 40, drop = 80;
    // Frame is due well in the future → hold (this is the normal steady state).
    CHECK(avDecide(-500, lead, drop, 0) == AvAction::Hold);
    // Inside the present lead window → show it.
    CHECK(avDecide(-10, lead, drop, 0) == AvAction::Present);
    CHECK(avDecide(0, lead, drop, 0) == AvAction::Present);
    // Slightly behind but under the drop threshold → still present, no judder.
    CHECK(avDecide(60, lead, drop, 0) == AvAction::Present);
    // Far behind → drop to catch up.
    CHECK(avDecide(200, lead, drop, 0) == AvAction::Drop);
    // Drop is rate-limited so a sustained decode shortfall degrades to lag, not a
    // black screen: never more than 1 dropped frame in a row per cap.
    CHECK(avDecide(200, lead, drop, 1) == AvAction::Present);
    CHECK(avDecide(200, lead, drop, 3) == AvAction::Present);

    // --- closed loop recovery from a decode stall ---
    // Steady state is drift ~0 (forced CFR keeps supply == schedule). Inject a 1 s
    // transport stall and require the corrector to pull drift back under the drop
    // threshold, without ever dropping two frames in a row.
    //
    // Model: the master clock only advances while we hold; a dropped frame costs
    // just its decode time, so dropping is how wall time is reclaimed.
    {
        const int64_t decodeCostMs = 5;
        int64_t tNow = 1000; // master clock jumped ahead while we were blocked
        int64_t presented = 0;
        int dropRun = 0, maxRun = 0, drops = 0;
        int64_t recoveredAfter = -1;
        for (int64_t i = 1; i <= 2000; ++i) {
            const int64_t frameMs = frameContentMs(presented + 1, 24000, 1001);
            int64_t d = avDriftMs(tNow, frameMs);
            const AvAction a = avDecide(d, lead, drop, dropRun);
            if (a == AvAction::Hold) {
                tNow = frameMs - lead; // wait for the frame to become due
                d = avDriftMs(tNow, frameMs);
            }
            if (a == AvAction::Drop) {
                ++dropRun;
                ++drops;
                if (dropRun > maxRun)
                    maxRun = dropRun;
            } else {
                dropRun = 0;
                if (recoveredAfter < 0 && d <= drop)
                    recoveredAfter = i;
            }
            ++presented; // frame consumed from the pipe either way
            tNow += decodeCostMs;
        }
        CHECK(maxRun == 1);               // never two blank frames back to back
        CHECK(drops > 0);                 // it actually corrected
        CHECK(recoveredAfter > 0 && recoveredAfter < 60); // ~2 s, not forever
        CHECK(avDriftMs(tNow, frameContentMs(presented, 24000, 1001)) < drop);
    }

    // --- known-duration pipe stall at EOF ---
    // Some PMS universal transcodes reach their advertised duration and then keep
    // the rawvideo pipe open without producing another full frame. The media loop
    // must classify that as terminal EOF once it is past known duration with no
    // partial frame in flight; otherwise timeline polls stay playing@duration.
    CHECK(!knownDurationEofStall(0, 30021, 29900, 0, 1200, 1200));
    CHECK(!knownDurationEofStall(0, 30021, 31500, 128, 1200, 1200));
    CHECK(!knownDurationEofStall(1260000, 1286942, 27050, 0, 200, 200));
    CHECK(!knownDurationEofStall(0, 0, 600000, 0, 600000, 600000));
    CHECK(!knownDurationEofStall(0, -1, 600000, 0, 600000, 600000));
    CHECK(!knownDurationEofStall(0, 60000, 59000, 0, 5000, 5000));
    CHECK(!knownDurationEofStall(0, 60000, 61000, 0, 999, 999));
    CHECK(!knownDurationEofStall(0, 60000, 61200, 0, 1200, 1200));
    CHECK(!knownDurationEofStall(0, 60000, 64000, 0, 4000, 4000));
    CHECK(!knownDurationEofStall(0, 60000, 66000, 0, 6000, 200));
    CHECK(!knownDurationEofStall(0, 60000, 74999, 0, 14999, 200));
    CHECK(knownDurationEofStall(0, 60000, 75000, 0, 15000, 200));
    CHECK(!knownDurationEofStall(0, 30021, 36000, 128, 4000, 6000));
    CHECK(knownDurationEofStall(0, 30021, 36000, 0, 6000, 6000));
    CHECK(knownDurationEofStall(0, 30021, 36000, 128, 6000, 6000));
    CHECK(knownDurationEofStall(1260000, 1286942, 33050, 0, 6000, 6000));

    // Audio-less / audio-never-started content must not disable the EOF-stall guard.
    // Once audio has produced bytes, however, continuing audio progress blocks EOF.
    CHECK(eofStallAudioSilenceMs(false, false, 6000, 0) == 6000);
    CHECK(eofStallAudioSilenceMs(true, false, 6000, 0) == 6000);
    CHECK(eofStallAudioSilenceMs(true, true, 6000, 200) == 200);
    CHECK(knownDurationEofStall(0, 30021, 36000, 0, 6000,
                                eofStallAudioSilenceMs(false, false, 6000, 0)));
    CHECK(knownDurationEofStall(0, 30021, 36000, 0, 6000,
                                eofStallAudioSilenceMs(true, false, 6000, 0)));
    CHECK(!knownDurationEofStall(0, 60000, 66000, 0, 6000,
                                 eofStallAudioSilenceMs(true, true, 6000, 200)));

    // --- rawvideo terminal-signal inventory ---
    CHECK(rawVideoTerminalSignal(true, false, false, false, false));  // explicit stop/seek
    CHECK(rawVideoTerminalSignal(false, true, false, false, false));  // read()==0
    CHECK(rawVideoTerminalSignal(false, false, true, false, false));  // read error
    CHECK(rawVideoTerminalSignal(false, false, false, true, false));  // short frame read
    CHECK(rawVideoTerminalSignal(false, false, false, false, true));  // known-duration stall
    CHECK(!rawVideoTerminalSignal(false, false, false, false, false)); // EAGAIN-only

    // --- startup hold-until-video (silicon RCA after co-arm regression) ---
    // Measured: early audio play → drops=13 odd-only counters; co-arm → drops=0
    // but grabber lip-sync −168 → −456 ms (real content lead unpaid). Success
    // requires drops~0 AND realContentOffset near 0 — daemon av_drift alone lies.
    CHECK(coArmedClockMs(206, 206) == 0);
    CHECK(realContentOffsetMs(206, 41) == 165);
    CHECK(realContentOffsetMs(0, 41) == -41);
    {
        const int64_t frame1Ms = frameContentMs(1, 24, 1);
        // Hardware latched audio_origin_ms=206 at first video frame under co-arm.
        const int64_t audioAtFrame1 = 206;
        const int64_t pacerDriftEarly = avDriftMs(audioAtFrame1, frame1Ms); // 165
        CHECK(pacerDriftEarly == 165);
        CHECK(avDecide(pacerDriftEarly, 40, 80, 0) == AvAction::Drop);

        const auto early =
            simulateStartupPacer(audioAtFrame1, StartupAudioMode::EarlyPlay, /*frames=*/26);
        const auto coarm =
            simulateStartupPacer(audioAtFrame1, StartupAudioMode::CoArmOrigin, /*frames=*/26);
        const auto hold =
            simulateStartupPacer(audioAtFrame1, StartupAudioMode::HoldUntilVideo, /*frames=*/26);

        std::printf("startup_sim EARLY drops=%d first_drift=%d first_real=%d steady_real=%d\n",
                    early.drops, early.firstDriftMs, early.firstRealOffsetMs,
                    early.steadyRealOffsetMs);
        std::printf("startup_sim COARM drops=%d first_drift=%d first_real=%d steady_real=%d\n",
                    coarm.drops, coarm.firstDriftMs, coarm.firstRealOffsetMs,
                    coarm.steadyRealOffsetMs);
        std::printf("startup_sim HOLD  drops=%d first_drift=%d first_real=%d steady_real=%d\n",
                    hold.drops, hold.firstDriftMs, hold.firstRealOffsetMs,
                    hold.steadyRealOffsetMs);

        // RED: early play massacres frames (pixel-confirmed ~13 drops).
        CHECK(early.firstDriftMs == static_cast<int>(pacerDriftEarly));
        CHECK(early.drops >= 10);
        CHECK(early.drops <= 16);
        CHECK(early.maxDropRun == 1);
        if (early.drops < 10) {
            std::fprintf(stderr, "FAIL: early-play drops=%d < 10 — gate vacuous\n", early.drops);
            return 1;
        }

        // COARM looks perfect on pacer metrics but leaves real content lead unpaid
        // (the hardware regression). A test that only checked drops would be green
        // here — that is exactly the blindness we must not ship again.
        CHECK(coarm.drops <= 2);
        CHECK(coarm.firstDriftMs < 80);
        CHECK(coarm.steadyRealOffsetMs > 80); // still ~audio lead
        if (coarm.steadyRealOffsetMs <= 80) {
            std::fprintf(stderr,
                         "FAIL: co-arm model lost the real-offset defect (steady_real=%d)\n",
                         coarm.steadyRealOffsetMs);
            return 1;
        }

        // GREEN: hold-until-video — no massacre, real offset near 0 (lead band).
        CHECK(hold.drops <= 2);
        CHECK(hold.presents >= 24);
        CHECK(hold.firstDriftMs < 80);
        CHECK(std::abs(hold.steadyRealOffsetMs) <= 50);
        CHECK(std::abs(hold.firstRealOffsetMs) <= 80);
        if (hold.drops > 2 || std::abs(hold.steadyRealOffsetMs) > 50) {
            std::fprintf(stderr, "FAIL: hold-until-video drops=%d steady_real=%d\n", hold.drops,
                         hold.steadyRealOffsetMs);
            return 1;
        }
        std::printf("PASS startup hold-until-video: early_drops=%d coarm_real=%d hold_real=%d\n",
                    early.drops, coarm.steadyRealOffsetMs, hold.steadyRealOffsetMs);
    }

    if (fails) {
        std::fprintf(stderr, "test_avclock: %d failures\n", fails);
        return 1;
    }
    std::printf("test_avclock: OK\n");
    return 0;
}
