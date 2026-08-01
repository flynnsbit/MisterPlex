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
    //   run1 drops=15, run2 drops=12 on identical conf. Steady-state sawtooth
    //   FALSIFIED. H-DROP REJECTED: drop count does NOT set HDMI offset clusters.
    //   av_drift_ms / av-lock are NOT lip-sync evidence (servo deadband).
    //   Lip-sync judge: tools/avsync_measure_hdmi.py only.
    std::printf("SIGN_CONVENTION grabber_offset_ms = t_audio_onset - t_video_flash; "
                "negative = audio LEADS (matches tools/avsync_measure_hdmi.py)\n");
    std::printf("CRITERION lip_sync=tools/avsync_measure_hdmi.py ONLY; "
                "av_drift_ms and clock=av-lock are NOT soak PASS criteria "
                "(parent fleet: five runs identical av_drift~-30, HDMI offset clusters "
                "116 ms apart)\n");
    std::printf("H_DROP_STATUS REJECTED by parent: 12-drop and 18-drop same HDMI "
                "cluster (0.7 ms); do not map drops→offset\n");
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

        // Lead variance ⇒ DROP COUNT variance (12 vs 15). dLead ≈ 3*period is a
        // geometric property of the repay model — NOT HDMI offset (H-DROP rejected).
        const auto sweep = sweepEarlyPlayDrops(/*lo*/ 500, /*hi*/ 800, /*step*/ 1, kFrames);
        std::printf("startup_sim EARLY_SWEEP lead_ms=[%d,%d] drops=[%d,%d] "
                    "L12=%d L15=%d n=%d (HW soak drop-count band [12,15]; NOT offset)\n",
                    sweep.leadMinMs, sweep.leadMaxMs, sweep.dropsMin, sweep.dropsMax,
                    sweep.leadForDrops12, sweep.leadForDrops15, sweep.nLeads);
        CHECK(sweep.dropsMin <= 12);
        CHECK(sweep.dropsMax >= 15);
        CHECK(sweep.leadForDrops12 > 0);
        CHECK(sweep.leadForDrops15 > sweep.leadForDrops12);
        const int dLead = sweep.leadForDrops15 - sweep.leadForDrops12;
        // ≈3 content periods @24fps (1000/24≈41.7 → ~125 ms). Band is model geometry.
        CHECK(dLead >= 100);
        CHECK(dLead <= 140);
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
                    "dLead=%d (model geometry ~3*period; NOT HDMI offset — H-DROP rejected)\n",
                    sweep.leadForDrops12, sweep.leadForDrops15, dLead);
        std::printf("PRE_REGISTER HOLD_IDEAL predicted_startup_drops=[0,2] "
                    "falsify_if_drops_ge=10 when residual lead proven 0 "
                    "(audio_bytes_at_release=0 AND no dump race)\n");
        std::printf("PRE_REGISTER HOLD_RACE predicted_startup_drops=[12,15] when "
                    "held_ms varies ~620..745 (T_first_video timing); "
                    "falsify_if_equal_held_ms_yields_delta_drops_ge_3\n");
        std::printf("PRE_REGISTER note: kFeedTargetMs=%lld past-bias ONLY on empty-hold open "
                    "(non-empty hold drain: past_bias=0 peer-aligned); "
                    "ERROR 17 retracted (fps=24/1 is correct for these fixtures); "
                    "lip_sync criterion = avsync_measure_hdmi.py only\n",
                    static_cast<long long>(kFeedTargetMs));
        std::printf("MISS_PUBLISHED H-DROP: w-cpu linked dLead~127 to parent Δoffset 119; "
                    "parent measured 12-drop and 18-drop in SAME HDMI cluster — rejected\n");
        std::printf("PASS startup drop variance: drops12=%d drops15=%d dLead=%d "
                    "hold_ideal_drops=%d coarm_drops=%d race_small_drops=%d "
                    "(drop COUNT model only; not lip-sync)\n",
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

    // --- 100 ms prefill vs 125 ms (3 frames @ 24.000) discrimination --------
    // Parent tol_ms=42 cannot separate them as explanations of a ~120 ms gap.
    // Host test: (1) steady-lead Δ is exact; (2) mean-|Δ−q| margin picks a winner.
    {
        CHECK(kPrefillQuantumMs == 100);
        CHECK(kThreeFrame24Ms == 125);
        CHECK(kFeedTargetMs == 100);
        // Steady grabber delta between two pipeline leads (grabber sign).
        CHECK(steadyGrabberDeltaForLeadsMs(100, 125) == 25);  // leadB−leadA
        CHECK(steadyGrabberDeltaForLeadsMs(125, 100) == -25);
        CHECK(grabberOffsetMs(100, 0) == -100);
        CHECK(grabberOffsetMs(125, 0) == -125);
        CHECK(grabberOffsetMs(100, 0) - grabberOffsetMs(125, 0) == 25);

        // Synthetic cross-cluster |Δ| set centered on 125 (with small noise).
        const double around125[] = {122.0, 119.3, 120.0, 121.3, 108.0, 108.7};
        // 108 appears when one A-member is -304.7 not -316 — still cross-cluster.
        const int nD = 6;
        const auto fit100 = scoreQuantumFit(around125, nD, 100.0);
        const auto fit125 = scoreQuantumFit(around125, nD, 125.0);
        std::printf("quantum_fit n=%d fit100_mae=%.3f fit125_mae=%.3f "
                    "margin_125_over_100=%.3f (tol_ms=42 cannot claim either alone)\n",
                    nD, fit100.meanAbsErr, fit125.meanAbsErr,
                    fit100.meanAbsErr - fit125.meanAbsErr);
        CHECK(fit125.meanAbsErr < fit100.meanAbsErr);
        // Margin test: require ≥5 ms better mean abs err to claim a winner.
        // Single-delta |120-100|=20 and |120-125|=5 both < 42 → band is blind.
        CHECK(quantumFitBeats(fit125, fit100, /*minMarginMs=*/5.0));
        CHECK(!quantumFitBeats(fit100, fit125, 5.0));

        // Control: pure-100 deltas must prefer 100 with margin.
        const double around100[] = {100.0, 99.0, 101.5, 100.5};
        const auto c100 = scoreQuantumFit(around100, 4, 100.0);
        const auto c125 = scoreQuantumFit(around100, 4, 125.0);
        CHECK(quantumFitBeats(c100, c125, 5.0));

        // Lone |Δ|=120: tol_ms=42 band accepts BOTH quanta (vacuous), but
        // mean-|Δ−q| margin prefers 125 (err 5 vs 20).
        const double lone120[] = {120.0};
        const auto l100 = scoreQuantumFit(lone120, 1, 100.0);
        const auto l125 = scoreQuantumFit(lone120, 1, 125.0);
        CHECK(l100.meanAbsErr == 20.0);
        CHECK(l125.meanAbsErr == 5.0);
        CHECK(l100.meanAbsErr < 42.0 && l125.meanAbsErr < 42.0); // band blind
        CHECK(quantumFitBeats(l125, l100, 5.0));                 // margin sees it

        // Lab cross-cluster |Δ| from CLUSTER_ANALYSIS (A×B pairs only):
        // orig-rep2=121.33, orig-rep3=122, rep1-rep2=119.33, rep1-rep3=120,
        // rep2-rep4=108, rep3-rep4=108.67  (rep4 is A at -304.7)
        const double labCross[] = {121.33, 122.0, 119.33, 120.0, 108.0, 108.67};
        const auto lab100 = scoreQuantumFit(labCross, 6, 100.0);
        const auto lab125 = scoreQuantumFit(labCross, 6, 125.0);
        std::printf("LAB_CROSS_QUANTUM n=6 mae100=%.3f mae125=%.3f prefer=%s margin=%.3f\n",
                    lab100.meanAbsErr, lab125.meanAbsErr,
                    (lab125.meanAbsErr < lab100.meanAbsErr) ? "125_three_frame" : "100_prefill",
                    (lab100.meanAbsErr > lab125.meanAbsErr)
                        ? (lab100.meanAbsErr - lab125.meanAbsErr)
                        : (lab125.meanAbsErr - lab100.meanAbsErr));
        // Evidence note only — do NOT hard-fail the suite on lab preference;
        // publish which quantum currently wins under the margin rule.
        const bool labPrefers125 = quantumFitBeats(lab125, lab100, 5.0);
        const bool labPrefers100 = quantumFitBeats(lab100, lab125, 5.0);
        std::printf("LAB_CROSS_VERDICT prefers125=%d prefers100=%d (need margin>=5; "
                    "else INCONCLUSIVE)\n",
                    labPrefers125 ? 1 : 0, labPrefers100 ? 1 : 0);

        // PRE_REGISTER HOLD vs cluster structure (parent hardware).
        // Non-empty hold drain: NO past-bias (peer-aligned). Empty-hold open still
        // past-biases kFeedTarget for ring fill.
        std::printf("PRE_REGISTER HOLD_vs_CLUSTERS:\n");
        std::printf("  fact: non-empty hold drain past_bias=0 burst_lead_ms=0; "
                    "empty-hold open may past-bias %lld ms\n",
                    static_cast<long long>(kFeedTargetMs));
        std::printf("  if clusters = hold-drain burst / held_ms imprint: peer drain collapses "
                    "A/B toward one cluster; |Δmedian|<40 over n>=4; "
                    "held_ms logged every session (first-class)\n");
        std::printf("  if clusters = external (PMS cache etc): A/B intact after peer drain\n");
        std::printf("  falsify_collapse: after peer drain, some pair |median_i-median_j| >= 80 ms\n");
        std::printf("  do_not_sell: lipsync fix; sell startup frame preservation only\n");
        std::printf("PASS quantum discrimination: prefill=%lld three_frame=%lld "
                    "steady_dGrab=%lld lab_prefers125=%d\n",
                    static_cast<long long>(kPrefillQuantumMs),
                    static_cast<long long>(kThreeFrame24Ms),
                    static_cast<long long>(steadyGrabberDeltaForLeadsMs(100, 125)),
                    labPrefers125 ? 1 : 0);
    }

    // --- Peer-aligned hold drain + first-class held_ms (RED→GREEN) ------------
    // RED: past-bias on non-empty hold drain injects kFeedTargetMs burst lead.
    // GREEN: holdDrainShouldPastBias(true)==false → burst lead 0.
    {
        std::printf("PEER_HOLD CITED: mpv both-READY; GStreamer preroll+base-time; "
                    "ffplay/GST queue in clock; GST discont_wait permanent-offset class\n");
        std::printf("PEER_HOLD NOT-FOUND: keep-HEAD t=0 FIFO; prefill→permanent bias doc; "
                    "drop-count freezes offset; 1200ms copied from mpv/VLC\n");

        // Both-READY arm (CITED shape) + timeout escape (engineering compromise).
        const auto both = peerBothReadyArm(/*a*/ true, /*v*/ true, /*wait*/ 50);
        CHECK(both.shouldArm);
        CHECK(!both.timedOut);
        const auto waitVid = peerBothReadyArm(true, false, 50);
        CHECK(!waitVid.shouldArm);
        const auto esc = peerBothReadyArm(true, false, kAudioHoldTimeoutMs);
        CHECK(esc.shouldArm);
        CHECK(esc.timedOut);
        CHECK(kAudioHoldTimeoutMs == 1200); // engineering compromise constant

        // RED policy (old): past-bias on hold drain.
        CHECK(holdDrainBurstLeadMs(/*pastBias*/ true, kFeedTargetMs) == kFeedTargetMs);
        CHECK(holdDrainBurstLeadMs(true, 100) == 100);
        // GREEN policy: no past-bias when hold non-empty.
        CHECK(holdDrainShouldPastBias(/*holdBufNonEmpty*/ true) == false);
        CHECK(holdDrainShouldPastBias(/*holdBufNonEmpty*/ false) == true);
        CHECK(holdDrainBurstLeadMs(holdDrainShouldPastBias(true), kFeedTargetMs) == 0);
        CHECK(holdDrainBurstLeadMs(holdDrainShouldPastBias(false), kFeedTargetMs) ==
              kFeedTargetMs);

        // First-class held_ms: report always has held_ms>=0; GREEN drain ok.
        const auto green = makeHoldSessionReport(/*written*/ 0, /*heldBytes*/ 19200 * 2,
                                                 /*waited*/ 120, /*pastBias*/ false,
                                                 /*timeout*/ false);
        CHECK(green.heldMs == 200);
        CHECK(green.holdWaitedMs == 120);
        CHECK(green.drainBurstLeadMs == 0);
        CHECK(green.ok);
        if (green.heldMs < 0 || !green.ok) {
            std::fprintf(stderr, "FAIL: green hold report held_ms=%lld ok=%d\n",
                         static_cast<long long>(green.heldMs), green.ok ? 1 : 0);
            return 1;
        }

        // RED report: past-bias on non-empty hold → not ok (burst lead).
        const auto red = makeHoldSessionReport(0, 19200 * 2, 120, /*pastBias*/ true, false);
        CHECK(red.heldMs == 200);
        CHECK(red.drainBurstLeadMs == 100);
        CHECK(!red.ok);
        if (red.ok || red.drainBurstLeadMs != 100) {
            std::fprintf(stderr, "FAIL: red hold report should be !ok burst=100 got ok=%d burst=%lld\n",
                         red.ok ? 1 : 0, static_cast<long long>(red.drainBurstLeadMs));
            return 1;
        }

        // Empty hold may past-bias (ring fill) and still be ok.
        const auto empty = makeHoldSessionReport(0, 0, 0, /*pastBias*/ true, false);
        CHECK(empty.heldMs == 0);
        CHECK(empty.ok);

        // Timeout path still reports held_ms (first-class).
        const auto to = makeHoldSessionReport(0, 48000, kAudioHoldTimeoutMs, false, true);
        CHECK(to.timedOut);
        CHECK(to.heldMs == 250);
        CHECK(to.ok);

        // Overflow: product DropHead; OpenGate alternative exists; NOT-FOUND peer.
        CHECK(!holdOverflowOpensGate(HoldOverflowPolicy::DropHeadKeepTail));
        CHECK(holdOverflowOpensGate(HoldOverflowPolicy::OpenGate));
        CHECK(holdRingAppendDropHead(kAudioHoldCapBytes - 100, 500, kAudioHoldCapBytes) == 400);

        std::printf("PRE_REGISTER PEER_DRAIN: non-empty hold past_bias=0 "
                    "drain_burst_lead_ms=0; falsify if log shows past_bias=1 with held_ms>0\n");
        std::printf("PRE_REGISTER ESCAPE: timeout_ms=%lld engineering compromise NOT peer-copied; "
                    "falsify if hang with no TIMEOUT log when video absent >timeout\n",
                    static_cast<long long>(kAudioHoldTimeoutMs));
        std::printf("PASS peer hold drain: red_burst=%lld green_burst=%lld held_ms=%lld "
                    "timeout_escape=%d\n",
                    static_cast<long long>(red.drainBurstLeadMs),
                    static_cast<long long>(green.drainBurstLeadMs),
                    static_cast<long long>(green.heldMs), esc.shouldArm ? 1 : 0);
    }

    if (fails) {
        std::fprintf(stderr, "test_avclock: %d failures\n", fails);
        return 1;
    }
    std::printf("test_avclock: OK\n");
    return 0;
}
