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

    // --- startup drop count + VARIANCE (PRIMARY score = DROP COUNT) ---------
    // Grabber convention (lab): offset_ms = t_audio_onset - t_video_flash;
    //   negative ⇒ audio LEADS. All printed offsets below use that sign.
    // Silicon soaks (parent): startup drops ONLY (first ~7 s), then flat;
    //   run1 drops=15, run2 drops=12 on identical conf; Δoffset ≈ 119 ms.
    std::printf("SIGN_CONVENTION grabber_offset_ms = t_audio_onset - t_video_flash; "
                "negative = audio LEADS (matches tools/avsync_measure_hdmi.py)\n");
    CHECK(coArmedClockMs(206, 206) == 0);
    CHECK(grabberOffsetMs(206, 41) == -165);
    CHECK(realContentOffsetMs(206, 41) == 165);
    CHECK(grabberOffsetMs(206, 41) == -realContentOffsetMs(206, 41));
    {
        const int64_t frame1Ms = frameContentMs(1, 24, 1);
        // Residual leads that produce HW soak counts under first-principles
        // repayment (drop wall=0, present wall=41). Small co-arm-era leads
        // (159/206) only yield a few drops once repayment is modeled — the
        // silicon 12–15 band needs ~0.6–0.75 s residual after gate open.
        const int64_t lead12 = 620; // → 12 drops
        const int64_t lead15 = 745; // → 15 drops
        const int64_t leadCoarm = 206;
        CHECK(avDriftMs(lead12, frame1Ms) > 80);
        CHECK(avDecide(avDriftMs(lead12, frame1Ms), 40, 80, 0) == AvAction::Drop);

        const int kFrames = 200; // long enough for quiet after repayment
        const auto early12 =
            simulateStartupPacer(lead12, StartupAudioMode::EarlyPlay, kFrames);
        const auto early15 =
            simulateStartupPacer(lead15, StartupAudioMode::EarlyPlay, kFrames);
        const auto coarm =
            simulateStartupPacer(leadCoarm, StartupAudioMode::CoArmOrigin, kFrames);
        const auto holdIdeal =
            simulateStartupPacer(lead15, StartupAudioMode::HoldUntilVideo, kFrames);

        std::printf("startup_sim EARLY lead=%lld drops=%d first_drift=%d "
                    "grabber_steady_ms=%d (neg=audio LEADS)\n",
                    static_cast<long long>(lead12), early12.drops, early12.firstDriftMs,
                    early12.steadyGrabberOffsetMs);
        std::printf("startup_sim EARLY lead=%lld drops=%d first_drift=%d "
                    "grabber_steady_ms=%d (neg=audio LEADS)\n",
                    static_cast<long long>(lead15), early15.drops, early15.firstDriftMs,
                    early15.steadyGrabberOffsetMs);
        std::printf("startup_sim COARM lead=%lld drops=%d first_drift=%d "
                    "grabber_steady_ms=%d (neg=audio LEADS)\n",
                    static_cast<long long>(leadCoarm), coarm.drops, coarm.firstDriftMs,
                    coarm.steadyGrabberOffsetMs);
        std::printf("startup_sim HOLD_IDEAL lead_in=%lld drops=%d first_drift=%d "
                    "grabber_steady_ms=%d (neg=audio LEADS)\n",
                    static_cast<long long>(lead15), holdIdeal.drops, holdIdeal.firstDriftMs,
                    holdIdeal.steadyGrabberOffsetMs);

        // PRIMARY: exact silicon soak outcomes from controlled residual leads.
        CHECK(early12.drops == 12);
        CHECK(early15.drops == 15);
        CHECK(early12.maxDropRun == 1);
        CHECK(early15.maxDropRun == 1);
        if (early12.drops != 12 || early15.drops != 15) {
            std::fprintf(stderr, "FAIL: early drops 12@%lld=%d 15@%lld=%d\n",
                         static_cast<long long>(lead12), early12.drops,
                         static_cast<long long>(lead15), early15.drops);
            return 1;
        }

        // Lead variance ⇒ drop variance (12 vs 15). dLead ≈ parent Δoffset 119 ms.
        const auto sweep = sweepEarlyPlayDrops(/*lo*/ 500, /*hi*/ 800, /*step*/ 1, kFrames);
        std::printf("startup_sim EARLY_SWEEP lead_ms=[%d,%d] drops=[%d,%d] "
                    "L12=%d L15=%d n=%d (HW soak band target [12,15])\n",
                    sweep.leadMinMs, sweep.leadMaxMs, sweep.dropsMin, sweep.dropsMax,
                    sweep.leadForDrops12, sweep.leadForDrops15, sweep.nLeads);
        CHECK(sweep.dropsMin <= 12);
        CHECK(sweep.dropsMax >= 15);
        CHECK(sweep.leadForDrops12 > 0);
        CHECK(sweep.leadForDrops15 > sweep.leadForDrops12);
        const int dLead = sweep.leadForDrops15 - sweep.leadForDrops12;
        CHECK(dLead >= 100);
        CHECK(dLead <= 140); // parent Δoffset 119 ms
        if (sweep.leadForDrops12 < 0 || sweep.leadForDrops15 < 0 || dLead < 100 || dLead > 140) {
            std::fprintf(stderr, "FAIL: sweep L12=%d L15=%d dLead=%d\n", sweep.leadForDrops12,
                         sweep.leadForDrops15, dLead);
            return 1;
        }

        // COARM: drops look fixed but grabber still shows large audio lead.
        CHECK(coarm.drops <= 2);
        CHECK(coarm.steadyGrabberOffsetMs < -80);
        if (coarm.drops > 2 || coarm.steadyGrabberOffsetMs >= -80) {
            std::fprintf(stderr, "FAIL: co-arm lost unpaid-lead defect drops=%d grab=%d\n",
                         coarm.drops, coarm.steadyGrabberOffsetMs);
            return 1;
        }

        // Ideal HOLD (zero residual at frame1): destroy ~0 frames.
        CHECK(holdIdeal.drops <= 2);
        CHECK(holdIdeal.presents >= kFrames - 2);
        if (holdIdeal.drops > 2) {
            std::fprintf(stderr, "FAIL: ideal hold drops=%d\n", holdIdeal.drops);
            return 1;
        }

        // Hold-dump RACE (timing perturbation): held_ms variance → 12 vs 15.
        // RED-before-green: same content, only T_first_video/held changes.
        const auto race12 = simulateHoldReleaseRace(/*held*/ 620);
        const auto race15 = simulateHoldReleaseRace(/*held*/ 745);
        const auto raceSmall = simulateHoldReleaseRace(/*held*/ 120);
        std::printf("hold-race held=620 residual=%lld drops=%d\n",
                    static_cast<long long>(race12.residualLeadMs), race12.drops);
        std::printf("hold-race held=745 residual=%lld drops=%d\n",
                    static_cast<long long>(race15.residualLeadMs), race15.drops);
        std::printf("hold-race held=120 residual=%lld drops=%d\n",
                    static_cast<long long>(raceSmall.residualLeadMs), raceSmall.drops);
        CHECK(race12.drops == 12);
        CHECK(race15.drops == 15);
        CHECK(race15.drops > race12.drops);
        CHECK(raceSmall.drops < race12.drops);
        CHECK(startupDropsForResidualLeadMs(sweep.leadForDrops12) == 12);
        CHECK(startupDropsForResidualLeadMs(sweep.leadForDrops15) == 15);
        if (race12.drops != 12 || race15.drops != 15) {
            std::fprintf(stderr, "FAIL: hold-race drops 12=%d 15=%d\n", race12.drops,
                         race15.drops);
            return 1;
        }

        // PRE-REGISTER for parent hardware — falsifiers explicit.
        std::printf("PRE_REGISTER mechanism: startup drops repay residual audio lead "
                    "after gate open; count = f(held_ms / dump race), NOT content bytes\n");
        std::printf("PRE_REGISTER residual_lead_ms for drops=12 ~= %d; for drops=15 ~= %d; "
                    "dLead=%d (parent Δoffset 119 ms)\n",
                    sweep.leadForDrops12, sweep.leadForDrops15, dLead);
        std::printf("PRE_REGISTER HOLD_IDEAL predicted_startup_drops=[0,2] "
                    "falsify_if_drops_ge=10 when residual lead proven 0 "
                    "(audio_bytes_at_release=0 AND no dump race)\n");
        std::printf("PRE_REGISTER HOLD_RACE predicted_startup_drops=[12,15] when "
                    "held_ms varies ~620..745 (T_first_video timing); "
                    "falsify_if_equal_held_ms_yields_delta_drops_ge_3\n");
        std::printf("PRE_REGISTER note: kFeedTargetMs=%lld past-bias always on after gate; "
                    "ERROR 17 retracted (fps=24/1 is correct for these fixtures)\n",
                    static_cast<long long>(kFeedTargetMs));
        std::printf("PASS startup drop variance: drops12=%d drops15=%d dLead=%d "
                    "hold_ideal_drops=%d coarm_drops=%d race_small_drops=%d\n",
                    early12.drops, early15.drops, dLead, holdIdeal.drops, coarm.drops,
                    raceSmall.drops);
    }

    // --- release-path content origin (must be 0, never 206) ---
    {
        const auto ok = checkAudioReleaseOrigin(/*written*/ 0, /*held*/ 192000 / 5); // 200 ms held
        CHECK(ok.ok);
        CHECK(ok.contentOriginMs == 0);
        CHECK(ok.audioBytesAtRelease == 0);
        CHECK(ok.heldMs == 200);
        const auto bad = checkAudioReleaseOrigin(/*written*/ 192000 * 206 / 1000, /*held*/ 0);
        CHECK(!bad.ok);
        CHECK(bad.contentOriginMs == 206);
        if (ok.contentOriginMs != 0 || bad.contentOriginMs != 206) {
            std::fprintf(stderr, "FAIL: release origin check vacuous ok=%lld bad=%lld\n",
                         static_cast<long long>(ok.contentOriginMs),
                         static_cast<long long>(bad.contentOriginMs));
            return 1;
        }
        std::printf("PASS release origin: ok_origin=0 bad_origin=%d held_ms=%d\n",
                    static_cast<int>(bad.contentOriginMs), static_cast<int>(ok.heldMs));
    }

    // --- handoff policy: seek/auto-next re-arm; pause/resume does not ---
    CHECK(handoffReArmsAudioHold(SessionHandoffKind::FreshPlay));
    CHECK(handoffReArmsAudioHold(SessionHandoffKind::SeekRestart));
    CHECK(handoffReArmsAudioHold(SessionHandoffKind::AutoNextRestart));
    CHECK(!handoffReArmsAudioHold(SessionHandoffKind::PauseResume));

    // --- multi-session seek / auto-next (residual lead class if early) ---
    {
        const int64_t kLead = 620; // silicon-class residual, not co-arm 206
        const auto red = simulateMultiSessionStartup(3, kLead, StartupAudioMode::EarlyPlay);
        const auto green = simulateMultiSessionStartup(3, kLead, StartupAudioMode::HoldUntilVideo);
        const auto coarm = simulateMultiSessionStartup(3, kLead, StartupAudioMode::CoArmOrigin);
        std::printf("multisession EARLY drops=%d worst_grabber=%d origin_nz=%d\n", red.totalDrops,
                    red.worstSteadyGrabberMs, red.sessionsOriginNonZero);
        std::printf("multisession HOLD  drops=%d worst_grabber=%d origin_nz=%d\n", green.totalDrops,
                    green.worstSteadyGrabberMs, green.sessionsOriginNonZero);
        std::printf("multisession COARM drops=%d worst_grabber=%d origin_nz=%d\n", coarm.totalDrops,
                    coarm.worstSteadyGrabberMs, coarm.sessionsOriginNonZero);
        // RED: every session pays silicon-class startup drops (~12 × 3).
        CHECK(red.totalDrops >= 30);
        CHECK(red.sessionsOriginNonZero == 3);
        // GREEN: ideal hold each restart — no massacre.
        CHECK(green.totalDrops <= 6);
        CHECK(green.sessionsOriginNonZero == 0);
        // COARM: drops look fine but grabber still audio-leads every session.
        CHECK(coarm.totalDrops <= 6);
        CHECK(coarm.sessionsOriginNonZero == 3);
        CHECK(coarm.worstSteadyGrabberMs < -80);
        if (green.sessionsOriginNonZero != 0 || red.totalDrops < 30) {
            std::fprintf(stderr, "FAIL: multisession gate vacuous\n");
            return 1;
        }
        std::printf("PASS multisession seek/auto-next: early_drops=%d hold_origin_nz=%d "
                    "coarm_origin_nz=%d\n",
                    red.totalDrops, green.sessionsOriginNonZero, coarm.sessionsOriginNonZero);
    }

    // --- pause/resume: must not re-arm hold (would mute until a non-event) ---
    {
        const auto good = simulatePauseResumeHold(/*reArmHoldOnResume=*/false);
        const auto bad = simulatePauseResumeHold(/*reArmHoldOnResume=*/true);
        CHECK(good.gateOpenAfterResume);
        CHECK(!good.audioMutedAfterResume);
        CHECK(!bad.gateOpenAfterResume);
        CHECK(bad.audioMutedAfterResume);
        std::printf("PASS pause/resume hold policy: good_open=%d bad_muted=%d\n",
                    good.gateOpenAfterResume ? 1 : 0, bad.audioMutedAfterResume ? 1 : 0);
    }

    // --- no first video: ring drop-head + timeout opens gate (B3/B4) ---
    {
        const int64_t fiveSec = 48000LL * 4LL * 5;
        const auto before = simulateHoldNoVideo(fiveSec, /*waitMs=*/500);
        CHECK(before.capped);
        CHECK(before.heldBytes == kAudioHoldCapBytes);
        CHECK(before.heldMs == kAudioHoldCapMs);
        CHECK(!before.wroteMrAudio);
        CHECK(!before.timedOpen);
        CHECK(before.droppedHeadBytes == fiveSec - kAudioHoldCapBytes);
        const auto after = simulateHoldNoVideo(fiveSec, /*waitMs=*/kAudioHoldTimeoutMs);
        CHECK(after.timedOpen);
        CHECK(after.wroteMrAudio);
        const auto small = simulateHoldNoVideo(19200, /*waitMs=*/0);
        CHECK(!small.capped);
        CHECK(!small.timedOpen);
        CHECK(holdRingAppendDropHead(kAudioHoldCapBytes - 100, 500, kAudioHoldCapBytes) == 400);
        CHECK(holdRingAppendDropHead(0, 1000, kAudioHoldCapBytes) == 0);
        std::printf("PASS hold no-video: cap=%lld timeout_ms=%lld timed_open=%d dropped_head=%lld\n",
                    static_cast<long long>(before.heldBytes),
                    static_cast<long long>(kAudioHoldTimeoutMs), after.timedOpen ? 1 : 0,
                    static_cast<long long>(before.droppedHeadBytes));
    }

    if (fails) {
        std::fprintf(stderr, "test_avclock: %d failures\n", fails);
        return 1;
    }
    std::printf("test_avclock: OK\n");
    return 0;
}
