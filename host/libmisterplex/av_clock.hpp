#pragma once
// A/V presentation clock for the product cast path.
//
// The raw RGB pipe carries no PTS, so `frameIndex` is the only notion of video
// time. Everything here is exact integer math on a rational rate.

#include <cstdint>
#include <cstdio>

namespace misterplex {

constexpr int kDefaultFpsNum = 24;
constexpr int kDefaultFpsDen = 1;

inline int64_t frameContentMs(int64_t frameIndex, int num, int den) {
    if (num <= 0 || den <= 0) {
        num = kDefaultFpsNum;
        den = kDefaultFpsDen;
    }
    return (frameIndex * 1000LL * static_cast<int64_t>(den)) / static_cast<int64_t>(num);
}

inline int64_t audioClockMs(int64_t audioBytes) {
    if (audioBytes <= 0)
        return 0;
    return (audioBytes * 1000LL) / (48000LL * 4LL);
}

// drift = audio clock − content time of the frame about to be shown.
//   drift < 0  video is ahead of audio → hold
//   drift > 0  video is behind audio → drop to catch up
inline int64_t avDriftMs(int64_t audioMs, int64_t frameMs) { return audioMs - frameMs; }

// DEPRECATED product fix — co-arm models unpaid lead. Unit tests only.
inline int64_t coArmedClockMs(int64_t rawAudibleMs, int64_t originMs) {
    return rawAudibleMs - originMs;
}

// ---------------------------------------------------------------------------
// Sign conventions (do not mix)
//
// DAEMON / pacer:
//   realContentOffsetMs = audioHeardContent − videoDisplayedContent
//   >0 ⇒ audio content LEADS picture
//
// GRABBER (tools/avsync_measure_hdmi.py, parent lab):
//   grabberOffsetMs = t_audio_onset − t_video_flash
//   <0 ⇒ audio LEADS picture
//
// Identity for content-aligned markers (same content time C):
//   grabberOffsetMs == −realContentOffsetMs == videoDisplayed − audioHeard
// ---------------------------------------------------------------------------
inline int64_t realContentOffsetMs(int64_t audioHeardContentMs, int64_t videoDisplayedContentMs) {
    return audioHeardContentMs - videoDisplayedContentMs;
}

// Grabber-sign offset. Prefer this in host tests the parent compares to silicon.
inline int64_t grabberOffsetMs(int64_t audioHeardContentMs, int64_t videoDisplayedContentMs) {
    return videoDisplayedContentMs - audioHeardContentMs; // == -realContentOffsetMs
}

// MrAudio ring target used by the product pump (mraudio_status.hpp). 100 ms.
// Always applied as past-bias prefill on first write (suppressStartupPrefill removed).
// This is a STEADY pipeline term, not the 12-vs-15 startup drop variance.
constexpr int64_t kFeedTargetMs = 100; // kFeedTargetBytes / (48000*4)

// --- Audio hold policy -------------------------------------------------------
constexpr int64_t kAudioHoldCapMs = 2000;
constexpr int64_t kAudioHoldCapBytes = 48000LL * 4LL * (kAudioHoldCapMs / 1000);
constexpr int64_t kAudioHoldTimeoutMs = 1200;

enum class SessionHandoffKind { FreshPlay, SeekRestart, AutoNextRestart, PauseResume };

inline bool handoffReArmsAudioHold(SessionHandoffKind k) {
    return k != SessionHandoffKind::PauseResume;
}

struct AudioReleaseCheck {
    bool ok = false;
    int64_t contentOriginMs = -1;
    int64_t audioBytesAtRelease = -1;
    int64_t heldMs = 0;
};

inline AudioReleaseCheck checkAudioReleaseOrigin(int64_t audioBytesWrittenBeforeRelease,
                                                 int64_t heldBytes) {
    AudioReleaseCheck c;
    c.audioBytesAtRelease = audioBytesWrittenBeforeRelease < 0 ? 0 : audioBytesWrittenBeforeRelease;
    if (heldBytes < 0)
        heldBytes = 0;
    c.heldMs = (heldBytes * 1000LL) / (48000LL * 4LL);
    c.contentOriginMs = (c.audioBytesAtRelease * 1000LL) / (48000LL * 4LL);
    c.ok = (c.audioBytesAtRelease == 0 && c.contentOriginMs == 0);
    return c;
}

struct PauseResumeHoldSim {
    bool gateOpenAfterResume = true;
    bool audioMutedAfterResume = false;
};

inline PauseResumeHoldSim simulatePauseResumeHold(bool reArmHoldOnResume) {
    PauseResumeHoldSim out{};
    out.gateOpenAfterResume = !reArmHoldOnResume;
    out.audioMutedAfterResume = reArmHoldOnResume;
    return out;
}

struct HoldNoVideoSim {
    int64_t heldBytes = 0;
    int64_t heldMs = 0;
    bool wroteMrAudio = false;
    bool capped = false;
    bool timedOpen = false;
    int64_t droppedHeadBytes = 0;
};

inline HoldNoVideoSim simulateHoldNoVideo(int64_t incomingBytes, int64_t waitMs = 0,
                                         int64_t capBytes = kAudioHoldCapBytes,
                                         int64_t timeoutMs = kAudioHoldTimeoutMs) {
    HoldNoVideoSim out{};
    if (capBytes < 0)
        capBytes = 0;
    if (incomingBytes < 0)
        incomingBytes = 0;
    if (incomingBytes > capBytes) {
        out.droppedHeadBytes = incomingBytes - capBytes;
        out.heldBytes = capBytes;
        out.capped = true;
    } else {
        out.heldBytes = incomingBytes;
    }
    out.heldMs = (out.heldBytes * 1000LL) / (48000LL * 4LL);
    out.timedOpen = waitMs >= timeoutMs;
    out.wroteMrAudio = out.timedOpen;
    return out;
}

inline int64_t holdRingAppendDropHead(int64_t curBytes, int64_t addBytes, int64_t capBytes) {
    if (capBytes < 0)
        capBytes = 0;
    if (curBytes < 0)
        curBytes = 0;
    if (addBytes < 0)
        addBytes = 0;
    const int64_t total = curBytes + addBytes;
    return total > capBytes ? total - capBytes : 0;
}

enum class AvAction { Present, Hold, Drop };

inline AvAction avDecide(int64_t driftMs, int64_t leadMs, int64_t dropMs, int dropRun,
                         int maxDropRun = 1) {
    if (dropMs > 0 && driftMs > dropMs && dropRun < maxDropRun)
        return AvAction::Drop;
    if (driftMs + leadMs < 0)
        return AvAction::Hold;
    return AvAction::Present;
}

// --- Startup pacer (host unit / silicon drop-count model) --------------------
//
// Silicon soaks (rk=8, 360 s, identical conf): startup drops ONLY, then flat.
//   run1 drops=15, run2 drops=12 — variance on byte-identical config.
//   100% startup drops; zero steady-state (sawtooth model FALSIFIED).
// Co-arm cleared drops but worsened grabber offset (−168 → −456).
// Ideal HOLD (lead=0 at frame1) predicts drops 0–2; silicon 12–18 means a
// residual lead remains after gate open (hold-dump race), not content mismatch.
//
// PARENT FLEET 2026-07-31 — H-DROP REJECTED: startup drop count does NOT set
// HDMI lip-sync offset (12-drop and 18-drop same cluster within 0.7 ms).
// av_drift_ms / clock=av-lock are blind to real lip-sync (servo deadband);
// only tools/avsync_measure_hdmi.py judges lip-sync. Do NOT map Δdrops→Δoffset.
//
// Product path (media_player.cpp Drop): skip present, next pipe frame ASAP.
// Audio pump concurrent. Fast Drop freezes audible vs frameIndex; frameMs
// jumps +period → drift falls ~one frame. Present ~period wall. maxDropRun=1
// staircase until drift ≤ 80, then quiet — matches "all drops in first ~7s".
//
// First-principles walls: Drop≈0; Present≈period @24fps (1000/24=41).
// Map (DROP COUNT only): lead 588→12, 715→15; Δlead=127 ms ≈3*period geometry,
// NOT a claim about HDMI offset clusters.
//
// Residual lead after hold gate (timing-sensitive, NOT content): held_ms,
// kFeedTargetMs past-bias, submitted-clock fallback, video lag.
// PRIMARY falsifiable output: predicted_startup_drops (HW band ~12–18).

enum class StartupAudioMode { EarlyPlay, CoArmOrigin, HoldUntilVideo };

// First-principles wall advances (ms). Drop freezes relative audio; Present ~period.
constexpr int64_t kStartupDropWallMs = 0;
constexpr int64_t kStartupPresentWallMs = 41; // 1000/24

struct StartupPacerSim {
    int drops = 0;
    int presents = 0;
    int holds = 0;
    int firstDriftMs = 0;
    int maxDropRun = 0;
    // GRABBER sign: <0 ⇒ audio leads. Do not compare to daemon realContentOffset.
    int firstGrabberOffsetMs = 0;
    int lastGrabberOffsetMs = 0;
    int steadyGrabberOffsetMs = 0;
    // Daemon sign kept for internal asserts only.
    int steadyDaemonOffsetMs = 0;
    int64_t audioLeadAtFrame1Ms = 0;
};

inline StartupPacerSim simulateStartupPacer(int64_t audioMsAtFirstFrame, StartupAudioMode mode,
                                           int frames, int64_t leadMs = 40, int64_t dropMs = 80,
                                           int fpsNum = 24, int fpsDen = 1,
                                           int64_t dropWallMs = kStartupDropWallMs,
                                           int64_t presentWallMs = kStartupPresentWallMs) {
    StartupPacerSim out{};
    const int64_t audioLeadAtFrame1 =
        (mode == StartupAudioMode::HoldUntilVideo) ? 0 : audioMsAtFirstFrame;
    out.audioLeadAtFrame1Ms = audioLeadAtFrame1;
    const int64_t origin =
        (mode == StartupAudioMode::CoArmOrigin) ? audioMsAtFirstFrame : 0;
    int64_t audioHeardContentMs = audioLeadAtFrame1;
    int64_t rawAudioMs = audioLeadAtFrame1;
    int dropRun = 0;
    int64_t grabSum = 0;
    int grabN = 0;
    bool gotFirstPresent = false;
    if (dropWallMs < 0)
        dropWallMs = 0;
    if (presentWallMs < 1)
        presentWallMs = 1;

    for (int i = 1; i <= frames; ++i) {
        const int64_t frameMs = frameContentMs(i, fpsNum, fpsDen);
        int64_t clock = coArmedClockMs(rawAudioMs, origin);
        int64_t drift = avDriftMs(clock, frameMs);
        if (i == 1)
            out.firstDriftMs = static_cast<int>(drift);
        AvAction act = avDecide(drift, leadMs, dropMs, dropRun);
        int holdGuard = 0;
        while (act == AvAction::Hold && holdGuard++ < 10000) {
            ++out.holds;
            rawAudioMs += 2;
            audioHeardContentMs += 2;
            clock = coArmedClockMs(rawAudioMs, origin);
            drift = avDriftMs(clock, frameMs);
            act = avDecide(drift, leadMs, dropMs, dropRun);
        }
        // Content period for this index (41/42 at 24/1 integer math).
        const int64_t periodMs =
            frameContentMs(i + 1, fpsNum, fpsDen) - frameMs;
        const int64_t presentAdvance =
            presentWallMs > 0 ? presentWallMs : (periodMs > 0 ? periodMs : 1);
        if (act == AvAction::Drop) {
            ++out.drops;
            ++dropRun;
            if (dropRun > out.maxDropRun)
                out.maxDropRun = dropRun;
            // Fast skip: audio barely moves; next i jumps frameMs by ~period.
            rawAudioMs += dropWallMs;
            audioHeardContentMs += dropWallMs;
        } else {
            ++out.presents;
            dropRun = 0;
            // Content-locked Present default: presentWall≈period so drift does
            // not ratchet after repayment (Hold/CoArm stay drop-free).
            rawAudioMs += presentAdvance;
            audioHeardContentMs += presentAdvance;
            const int64_t grab = grabberOffsetMs(audioHeardContentMs, frameMs);
            out.lastGrabberOffsetMs = static_cast<int>(grab);
            if (!gotFirstPresent) {
                gotFirstPresent = true;
                out.firstGrabberOffsetMs = static_cast<int>(grab);
            }
            if (i > frames / 2) {
                grabSum += grab;
                ++grabN;
            }
        }
    }
    out.steadyGrabberOffsetMs =
        grabN > 0 ? static_cast<int>(grabSum / grabN) : out.lastGrabberOffsetMs;
    out.steadyDaemonOffsetMs = -out.steadyGrabberOffsetMs;
    return out;
}

// Back-compat.
inline StartupPacerSim simulateStartupPacer(int64_t audioMsAtFirstFrame, bool coArm, int frames,
                                           int64_t leadMs = 40, int64_t dropMs = 80,
                                           int fpsNum = 24, int fpsDen = 1) {
    return simulateStartupPacer(audioMsAtFirstFrame,
                                coArm ? StartupAudioMode::CoArmOrigin : StartupAudioMode::EarlyPlay,
                                frames, leadMs, dropMs, fpsNum, fpsDen);
}

// Sweep audio lead → drop count. Models 12 vs 15 variance as lead variance.
struct StartupDropSweep {
    int leadMinMs = 0;
    int leadMaxMs = 0;
    int dropsMin = 0;
    int dropsMax = 0;
    int nLeads = 0;
    int leadForDrops12 = -1;
    int leadForDrops15 = -1;
};

inline StartupDropSweep sweepEarlyPlayDrops(int leadLoMs, int leadHiMs, int stepMs = 1,
                                           int frames = 200) {
    StartupDropSweep s{};
    s.leadMinMs = leadLoMs;
    s.leadMaxMs = leadHiMs;
    s.dropsMin = 1000000;
    s.dropsMax = -1000000;
    if (stepMs < 1)
        stepMs = 1;
    for (int lead = leadLoMs; lead <= leadHiMs; lead += stepMs) {
        const auto one = simulateStartupPacer(lead, StartupAudioMode::EarlyPlay, frames);
        if (one.drops < s.dropsMin)
            s.dropsMin = one.drops;
        if (one.drops > s.dropsMax)
            s.dropsMax = one.drops;
        if (one.drops == 12 && s.leadForDrops12 < 0)
            s.leadForDrops12 = lead;
        if (one.drops == 15 && s.leadForDrops15 < 0)
            s.leadForDrops15 = lead;
        ++s.nLeads;
    }
    if (s.nLeads == 0) {
        s.dropsMin = 0;
        s.dropsMax = 0;
    }
    return s;
}

// held_ms at gate open → residual lead seen by pacer (first-order dump race).
// Ideal hold keeps content_origin=0, but writePacedChunk past-biases by
// kFeedTargetMs and may use submitted-byte clock until status is known — so a
// large hold buffer can burst ahead of frameIndex before audible tracks heard.
// videoCatchupLagMs: extra positive drift from slow first presents.
struct HoldReleaseRaceSim {
    int64_t residualLeadMs = 0;
    int drops = 0;
    int firstDriftMs = 0;
    int steadyGrabberOffsetMs = 0;
};

inline HoldReleaseRaceSim simulateHoldReleaseRace(int64_t heldMs, int64_t feedTargetMs = 100,
                                                  int64_t statusUnknownMs = 80,
                                                  int64_t videoCatchupLagMs = 0,
                                                  int frames = 200) {
    HoldReleaseRaceSim out{};
    if (heldMs < 0)
        heldMs = 0;
    if (feedTargetMs < 0)
        feedTargetMs = 0;
    if (statusUnknownMs < 0)
        statusUnknownMs = 0;
    if (videoCatchupLagMs < 0)
        videoCatchupLagMs = 0;
    // First-order: residual ≈ held (dump races frame1) + lag. Feed/status knobs
    // bound the minimum burst when held is small; when held is large the whole
    // buffer is the race window (past-bias lets the pump run without sleep).
    int64_t burstFloor = feedTargetMs + statusUnknownMs;
    if (burstFloor > heldMs)
        burstFloor = heldMs;
    out.residualLeadMs = (heldMs > burstFloor ? heldMs : burstFloor) + videoCatchupLagMs;
    const auto pac =
        simulateStartupPacer(out.residualLeadMs, StartupAudioMode::EarlyPlay, frames);
    out.drops = pac.drops;
    out.firstDriftMs = pac.firstDriftMs;
    out.steadyGrabberOffsetMs = pac.steadyGrabberOffsetMs;
    return out;
}

inline int startupDropsForResidualLeadMs(int64_t residualLeadMs, int frames = 200) {
    return simulateStartupPacer(residualLeadMs, StartupAudioMode::EarlyPlay, frames).drops;
}

struct MultiSessionStartupSim {
    int sessions = 0;
    int totalDrops = 0;
    int worstSteadyGrabberMs = 0; // most audio-lead (most negative) steady grabber
    int sessionsOriginNonZero = 0;
};

inline MultiSessionStartupSim simulateMultiSessionStartup(int sessions, int64_t audioLeadMs,
                                                          StartupAudioMode mode,
                                                          int framesPerSession = 200) {
    MultiSessionStartupSim out{};
    out.sessions = sessions < 0 ? 0 : sessions;
    out.worstSteadyGrabberMs = 0;
    bool any = false;
    for (int s = 0; s < out.sessions; ++s) {
        const auto one = simulateStartupPacer(audioLeadMs, mode, framesPerSession);
        out.totalDrops += one.drops;
        if (!any || one.steadyGrabberOffsetMs < out.worstSteadyGrabberMs) {
            out.worstSteadyGrabberMs = one.steadyGrabberOffsetMs;
            any = true;
        }
        // Unpaid-lead class: Early/CoArm start with audio ahead of frame 1; Hold zeros it.
        // (Do not use post-drop firstGrabber — EarlyPlay repays lead via drops.)
        if (one.audioLeadAtFrame1Ms >= 80)
            ++out.sessionsOriginNonZero;
    }
    return out;
}

// --- Cluster / quantum discrimination (grabber medians) ----------------------
// Parent lab: two discrete offset clusters ~120 ms apart; within-cluster
// spread 0.7–2 ms; av_drift_ms blind to the gap. A 42 ms PASS band cannot
// tell 100 ms (kFeedTarget) from 125 ms (3 frames @ 24.000). Use mean |Δ−q|
// over CROSS-cluster median deltas and require a margin.
//
// Convention: deltas are absolute |median_i − median_j| for pairs that land
// in different clusters. Smaller meanAbsErr wins.

struct QuantumFit {
    double quantumMs = 0;
    double meanAbsErr = 0;
    double rmse = 0;
    int n = 0;
};

inline QuantumFit scoreQuantumFit(const double* absCrossDeltasMs, int n, double quantumMs) {
    QuantumFit f{};
    f.quantumMs = quantumMs;
    f.n = n < 0 ? 0 : n;
    if (f.n == 0 || !absCrossDeltasMs || quantumMs <= 0)
        return f;
    double sae = 0;
    double sse = 0;
    for (int i = 0; i < f.n; ++i) {
        double d = absCrossDeltasMs[i];
        if (d < 0)
            d = -d;
        const double e = d - quantumMs;
        const double ae = e < 0 ? -e : e;
        sae += ae;
        sse += ae * ae;
    }
    f.meanAbsErr = sae / static_cast<double>(f.n);
    const double mse = sse / static_cast<double>(f.n);
    // Newton sqrt, header-only (no <cmath>).
    if (mse <= 0) {
        f.rmse = 0;
    } else {
        double r = mse;
        for (int k = 0; k < 12; ++k)
            r = 0.5 * (r + mse / r);
        f.rmse = r;
    }
    return f;
}

// True when winner's mean abs err beats loser by at least minMarginMs.
// Parent tol_ms=42 cannot separate 100 vs 125 for a single ~120 delta;
// margin test on the *error difference* can (need |err100-err125| >= minMargin).
inline bool quantumFitBeats(const QuantumFit& winner, const QuantumFit& loser,
                            double minMarginMs) {
    if (winner.n <= 0 || loser.n <= 0 || winner.n != loser.n)
        return false;
    if (minMarginMs < 0)
        minMarginMs = 0;
    return (loser.meanAbsErr - winner.meanAbsErr) >= minMarginMs;
}

// Steady pipeline lead difference → grabber Δ (sign: neg = audio leads).
// grabber(lead) ≈ −lead for content-aligned markers after lock.
// Discriminates 100 vs 125 by construction: Δgrabber = −(L1−L2).
inline int64_t steadyGrabberDeltaForLeadsMs(int64_t leadAMs, int64_t leadBMs) {
    // grabber(A) - grabber(B) = (−leadA) − (−leadB) = leadB − leadA
    return leadBMs - leadAMs;
}

// Prefill quantum (product) and 3-frame @ 24.000 fps.
constexpr int64_t kPrefillQuantumMs = kFeedTargetMs;          // 100
constexpr int64_t kThreeFrame24Ms = (1000 * 3) / 24;          // 125 exactly (integer)

inline bool rawVideoTerminalSignal(bool explicitStopOrSeek, bool readZero, bool readError,
                                   bool shortRead, bool knownDurationStall) {
    return explicitStopOrSeek || readZero || readError || shortRead || knownDurationStall;
}

inline int64_t eofStallAudioSilenceMs(bool wantAudio, bool audioSeen, int64_t noVideoMs,
                                      int64_t noAudioMs) {
    return (!wantAudio || !audioSeen) ? noVideoMs : noAudioMs;
}

inline bool knownDurationEofStall(int64_t startMs, int64_t durationMs, int64_t elapsedMs,
                                  int64_t partialFrameBytes, int64_t noVideoMs, int64_t noAudioMs,
                                  int64_t graceMs = 5000) {
    if (durationMs <= 0 || elapsedMs < 0 || partialFrameBytes < 0)
        return false;
    if (graceMs < 0)
        graceMs = 0;
    const int64_t audioOverrideMs = graceMs * 3;
    const bool audioQuiet = noAudioMs >= graceMs || noVideoMs >= audioOverrideMs;
    return startMs + elapsedMs >= durationMs + graceMs && noVideoMs >= graceMs && audioQuiet;
}

} // namespace misterplex
