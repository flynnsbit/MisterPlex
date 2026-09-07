// Unit tests for the A/V master-clock math (host/libmisterplex/av_clock.hpp).
//
// This is the math that shipped wrong: the present loop paced frames with
// `frameIndex * 1000 / fps` and an integer fps, so 23.976 fps content was scheduled
// at 24.000 and video crept ahead of audio by ~1 ms/s — ~234 ms by 3:54 and ~5.5 s
// by the end of a 91 minute episode.
#include "libmisterplex/av_clock.hpp"
#if __has_include("libmisterplex/fabric_direct.hpp")
#include "libmisterplex/fabric_direct.hpp"
#endif

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

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
    CHECK(frameContentUs(0, 24, 1) == 0);
    CHECK(frameContentUs(24, 24, 1) == 1000000);
    CHECK(frameContentUs(24000, 24000, 1001) == 1001000000);

    struct RateCase {
        int num;
        int den;
        int frames_per_marker;
        int marker_period_ms;
        const char* label;
    };
    const RateCase rates[] = {
        {24000, 1001, 24, 1001, "24000/1001"},
        {24, 1, 24, 1000, "24/1"},
        {25, 1, 25, 1000, "25/1"},
        {30000, 1001, 30, 1001, "30000/1001"},
        {30, 1, 30, 1000, "30/1"},
    };

    for (const auto& rate : rates) {
        CHECK(frameContentMs(rate.frames_per_marker, rate.num, rate.den) ==
              rate.marker_period_ms);
        CHECK(frameContentUs(rate.frames_per_marker, rate.num, rate.den) ==
              static_cast<int64_t>(rate.marker_period_ms) * 1000);

        // Exercise a non-round frame index after many hours. Integer truncation
        // may move within [0,1) ms but must never accumulate.
        const int64_t n = static_cast<int64_t>(rate.frames_per_marker) * 25000 + 7;
        const long double exact = static_cast<long double>(n) * 1000.0L * rate.den / rate.num;
        const int64_t got = frameContentMs(n, rate.num, rate.den);
        CHECK(static_cast<long double>(got) <= exact);
        CHECK(exact - static_cast<long double>(got) < 1.0L);
        CHECK(frameContentMs(n + 1, rate.num, rate.den) > got);

        const long double exactUs =
            static_cast<long double>(n) * 1000000.0L * rate.den / rate.num;
        const int64_t gotUs = frameContentUs(n, rate.num, rate.den);
        CHECK(static_cast<long double>(gotUs) <= exactUs);
        CHECK(exactUs - static_cast<long double>(gotUs) < 1.0L);
        CHECK(frameContentUs(n + 1, rate.num, rate.den) > gotUs);

        // Fractional-frame rounding error is a bounded sawtooth, not evidence
        // of monotonic clock drift. Pin both directions so a future test cannot
        // mistake endpoint slope for the whole run.
        if (rate.den != 1) {
            bool rose = false;
            bool fell = false;
            long double prev = 0.0L;
            for (int64_t i = 1; i <= 200; ++i) {
                const long double ideal =
                    static_cast<long double>(i) * 1000.0L * rate.den / rate.num;
                const long double err = ideal - frameContentMs(i, rate.num, rate.den);
                if (i > 1) {
                    rose = rose || err > prev;
                    fell = fell || err < prev;
                }
                prev = err;
            }
            CHECK(rose && fell);

            // The historical integer-bucket bug is still several seconds wrong
            // over an episode at both NTSC fractional rates.
            const int64_t episode_frames =
                static_cast<int64_t>(rate.frames_per_marker) * 60 * 90;
            const long double episode_exact =
                static_cast<long double>(episode_frames) * 1000.0L * rate.den / rate.num;
            const int64_t bucketed =
                (episode_frames * 1000LL) / static_cast<int64_t>(rate.frames_per_marker);
            CHECK(episode_exact - static_cast<long double>(bucketed) > 5000.0L);
        }
    }

    // Bad rates fall back to the 24/1 default rather than dividing by zero.
    CHECK(frameContentMs(24, 0, 1) == frameContentMs(24, kDefaultFpsNum, kDefaultFpsDen));
    CHECK(frameContentMs(24, 24, 0) == frameContentMs(24, kDefaultFpsNum, kDefaultFpsDen));
    CHECK(frameContentUs(24, 0, 1) == frameContentUs(24, kDefaultFpsNum, kDefaultFpsDen));
    CHECK(frameContentUs(24, 24, 0) == frameContentUs(24, kDefaultFpsNum, kDefaultFpsDen));

    // --- audio master clock (48 kHz stereo s16le = 192 000 B/s) ---
    CHECK(audioClockMs(0) == 0);
    CHECK(audioClockMs(192000) == 1000);
    CHECK(audioClockMs(192000LL * 3600) == 3600000);
    CHECK(audioClockUs(0) == 0);
    CHECK(audioClockUs(192) == 1000);
    CHECK(audioClockUs(192000) == 1000000);

    // Execute the production INNER AU wait; no outer-loop pause handler runs.
    // Resume after three seconds while this AU is still outside its lead window.
    int64_t wallUs = 0, pausedUs = 0;
    bool paused = false, resumedWithFutureAu = false;
    int waitCalls = 0;
    const auto paced = waitForCompressedAccessUnit(80000, [] { return true; },
        [] { return true; }, [&] {
            const int64_t activeUs = activePlaybackClockUs(wallUs, pausedUs);
            if (waitCalls == 3005)
                resumedWithFutureAu = !paused && activeUs + 40000 < 80000;
            return CompressedPacingSnapshot{paused, activeUs, 0, activeUs};
        }, [&] {
            ++waitCalls;
            if (waitCalls == 5) paused = true;
            wallUs += 1000;
            if (paused) pausedUs += 1000;
            if (waitCalls == 3005) paused = false;
        });
    CHECK(paced == CompressedPacingResult::Due);
    CHECK(resumedWithFutureAu);
    CHECK(pausedUs > 2000000);
    CHECK(wallUs > 3000000);
    CHECK(activePlaybackClockUs(wallUs, pausedUs) == 40000);

    // An actually stalled audio/video clock still expires after two ACTIVE seconds.
    wallUs = 0;
    CHECK(waitForCompressedAccessUnit(80000, [] { return true; }, [] { return true; },
        [&] { return CompressedPacingSnapshot{false, wallUs, 0, 0}; },
        [&] { wallUs += 1000; }) == CompressedPacingResult::Stalled);
    CHECK(wallUs == 2001000);
    bool keepWaiting = true;
    CHECK(waitForCompressedAccessUnit(80000, [&] { return keepWaiting; },
        [] { return true; },
        [] { return CompressedPacingSnapshot{true, 0, 0, 0}; },
        [&] { keepWaiting = false; }) == CompressedPacingResult::Cancelled);
    // A frozen frame's MVPS audio count must not freeze the current DMA master clock.
    const int64_t frozenPresentationSamples = 0;
    int64_t liveSamples = 0;
    wallUs = 0;
    CHECK(waitForCompressedAccessUnit(80000, [] { return true; }, [] { return true; },
        [&] { return CompressedPacingSnapshot{
            false, wallUs, 0, audioClockUs(liveSamples * 4)}; },
        [&] { wallUs += 2000; liveSamples += 96; }) == CompressedPacingResult::Due);
    CHECK(frozenPresentationSamples == 0 && liveSamples == 1920);

    // --- drift polarity ---
    // drift > 0 means the master clock is past this frame's content time → video behind.
    CHECK(avDriftMs(1000, 900) == 100);
    CHECK(avDriftMs(900, 1000) == -100);

    // --- v0.4 480p A/V contract ---
    // Present lead default 40 ms. 10 ms early is inside the lead window.
    // 480p/L4 present-every-decoded is hold-only: conf 80 ms drop becomes 0.
    // RED twin: lead default 0 is the HEAD lie and must fail this gate.
    CHECK(kDefaultPresentLeadMs != 0);
    // GREEN
    CHECK(kDefaultPresentLeadMs == 40);
    CHECK(avDecide(-10, 40, 80, 0) == AvAction::Present);
    CHECK(avResyncDropMsForPresent(80, true) == 0);
    CHECK(avResyncDropMsForPresent(80, false) == 80);
    CHECK(avResyncDropMsForPresent(0, false) == 0);
    // Late frame on the 480p hold-only path presents; it must not 2:1-drop.
    CHECK(avDecide(200, 40, avResyncDropMsForPresent(80, true), 0) == AvAction::Present);
    const int64_t lead = kDefaultPresentLeadMs, drop = 80;
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

    // --- terminal-state classification ---
    // Only natural EOF with content is success-shaped "ended"/auto-next.
    CHECK(classifyPlaybackTerminalState(false, false, true) ==
          PlaybackTerminalState::Ended);
    CHECK(classifyPlaybackTerminalState(false, false, false) ==
          PlaybackTerminalState::Stopped);
    // A strict true480 send failure after many decoded frames must remain a
    // failure and never become natural EOF merely because hadContent is true.
    CHECK(classifyPlaybackTerminalState(false, true, true) ==
          PlaybackTerminalState::Stopped);
    CHECK(classifyPlaybackTerminalState(false, true, false) ==
          PlaybackTerminalState::Stopped);
    CHECK(classifyPlaybackTerminalState(true, true, true) ==
          PlaybackTerminalState::None);
    CHECK(classifyFpgaPlaybackTerminalState(true, false, true, true, true, true) ==
          PlaybackTerminalState::Ended);
    CHECK(classifyFpgaPlaybackTerminalState(true, false, true, false, true, true) ==
          PlaybackTerminalState::Stopped);
    CHECK(classifyFpgaPlaybackTerminalState(true, false, true, true, false, true) ==
          PlaybackTerminalState::Stopped);
    CHECK(classifyFpgaPlaybackTerminalState(true, true, true, true, true, true) ==
          PlaybackTerminalState::Stopped);
    CHECK(classifyFpgaPlaybackTerminalState(true, false, false, true, true, true) ==
          PlaybackTerminalState::Stopped);
    CHECK(classifyFpgaPlaybackTerminalState(true, false, true, true, true, false) ==
          PlaybackTerminalState::Stopped);
    CHECK(classifyFpgaPlaybackTerminalState(false, false, true, true, true, true) ==
          PlaybackTerminalState::None);

    // Execute the production FPGA callback adapter, not just terminal classification.
    std::vector<std::string> terminalReports;
    uint64_t generation = 11;
    bool stopped = false;
    const auto progress = [&](const std::string& state, int64_t position, int64_t duration) {
        CHECK(position == 7958 && duration == 8000);
        terminalReports.push_back(state);
    };
    const auto report = [&](PlaybackTerminalState terminal) {
        reportFpgaPlaybackTerminal(terminal, [&] { return generation == 11; },
            [&] { return stopped; }, progress, 7958, 8000);
    };
    report(classifyFpgaPlaybackTerminalState(true, false, true, true, true, true));
    CHECK(terminalReports.size() == 1 && terminalReports.back() == "ended");
    report(classifyFpgaPlaybackTerminalState(true, false, true, false, true, true));
    CHECK(terminalReports.size() == 2 && terminalReports.back() == "stopped");
    stopped = true;
    report(PlaybackTerminalState::Ended);
    CHECK(terminalReports.size() == 3 && terminalReports.back() == "stopped");
    stopped = false;
    report(PlaybackTerminalState::None);
    CHECK(terminalReports.size() == 3);
    generation = 12;
    report(PlaybackTerminalState::Ended);
    CHECK(terminalReports.size() == 3);
    generation = 11;
    reportFpgaPlaybackTerminal(PlaybackTerminalState::Ended,
        [&] { return generation == 11; },
        [&] { generation = 12; return false; }, progress, 7958, 8000);
    CHECK(terminalReports.size() == 3);

    // Sustained lateness must alternate drop/present, never produce a burst.
    for (const auto& rate : rates) {
        (void)rate;
        int run = 0;
        int maxRun = 0;
        for (int i = 0; i < 40; ++i) {
            const AvAction a = avDecide(500, lead, drop, run);
            if (a == AvAction::Drop) {
                ++run;
                if (run > maxRun)
                    maxRun = run;
            } else {
                run = 0;
            }
        }
        CHECK(maxRun == 1);
    }

    // --- closed loop recovery from a decode stall ---
    // Repeat the recovery model at every required source rate. A dropped frame
    // costs only decode time, so alternating drops reclaim wall time without a
    // consecutive blank-frame burst.
    for (const auto& rate : rates) {
        const int64_t decodeCostMs = 5;
        int64_t tNow = 1000;
        int64_t consumed = 0;
        int dropRun = 0;
        int maxRun = 0;
        int drops = 0;
        int64_t recoveredAfter = -1;
        for (int64_t i = 1; i <= 2000; ++i) {
            const int64_t frameMs = frameContentMs(consumed + 1, rate.num, rate.den);
            int64_t d = avDriftMs(tNow, frameMs);
            const AvAction a = avDecide(d, lead, drop, dropRun);
            if (a == AvAction::Hold) {
                tNow = frameMs - lead;
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
            ++consumed;
            tNow += decodeCostMs;
        }
        CHECK(maxRun == 1);
        CHECK(drops > 0);
        CHECK(recoveredAfter > 0 && recoveredAfter < 60);
        CHECK(avDriftMs(tNow, frameContentMs(consumed, rate.num, rate.den)) < drop);
    }

    if (fails) {
        std::fprintf(stderr, "test_avclock: %d failures\n", fails);
        return 1;
    }
    std::printf("test_avclock: OK\n");
    return 0;
}
