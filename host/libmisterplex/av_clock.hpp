#pragma once
// A/V presentation clock for the product cast path.
//
// The raw RGB pipe carries no PTS, so `frameIndex` is the only notion of video
// time. That makes the assumed content rate load-bearing: pacing 23.976 fps
// content at 24 fps makes video lead audio by ~1 ms/s, which is invisible in a
// 12 s test clip but reaches ~234 ms by 3:54 and ~5.5 s across a 91-minute
// episode. Everything here is exact integer math on a rational rate.

#include <cstdint>

namespace misterplex {

// Default rate when PMS metadata gives us nothing. The drift corrector absorbs
// the error, but log it — an unknown rate means degraded lipsync.
constexpr int kDefaultFpsNum = 24;
constexpr int kDefaultFpsDen = 1;

// Content timestamp (ms) of frame `frameIndex` at rate num/den.
// frameIndex is 1-based (the frame just presented), matching the present loop.
// int64 throughout: 131 400 frames * 1000 * 1001 stays far inside the range.
inline int64_t frameContentMs(int64_t frameIndex, int num, int den) {
    if (num <= 0 || den <= 0) {
        num = kDefaultFpsNum;
        den = kDefaultFpsDen;
    }
    return (frameIndex * 1000LL * static_cast<int64_t>(den)) / static_cast<int64_t>(num);
}

// Audio master clock (ms) from bytes handed to MrAudio (s16le stereo @ 48 kHz).
inline int64_t audioClockMs(int64_t audioBytes) {
    if (audioBytes <= 0)
        return 0;
    return (audioBytes * 1000LL) / (48000LL * 4LL);
}

// drift = audio clock − content time of the frame about to be shown.
//   drift < 0  video is ahead of audio (audio sounds late) → hold
//   drift > 0  video is behind audio (we are late) → drop to catch up
inline int64_t avDriftMs(int64_t audioMs, int64_t frameMs) { return audioMs - frameMs; }

// DEPRECATED as a product fix: subtracting an origin at first video frame
// zeroes the *pacer's* drift without moving photons/samples. Hardware (rk=8):
// co-arm cleared drops (13→0) but moved grabber lip-sync −168 → −456 ms
// (audio even earlier). Kept only so unit tests can model that failure mode.
inline int64_t coArmedClockMs(int64_t rawAudibleMs, int64_t originMs) {
    return rawAudibleMs - originMs;
}

// Real content A/V offset the grabber measures (calibration-free in a before/
// after delta): content time of audio being heard minus content time of the
// frame on screen. >0 ⇒ audio content leads picture (the lab failure sign).
inline int64_t realContentOffsetMs(int64_t audioHeardContentMs, int64_t videoDisplayedContentMs) {
    return audioHeardContentMs - videoDisplayedContentMs;
}

enum class AvAction {
    Present, // show this frame
    Hold,    // wait, video is running ahead of the master clock
    Drop,    // skip presenting, we are too far behind to catch up by waiting
};

// Decide what to do with the frame we just decoded.
//   leadMs      small allowed video lead so the vsync path is never starved
//   dropMs      drift past which a late frame is dropped (0 disables dropping)
//   dropRun     how many frames we have dropped back-to-back
//   maxDropRun  cap on consecutive drops so a stall cannot shred the picture
//
// Dropping is only safe because the FFmpeg chain is forced to CFR at this same
// rate: supply then matches the schedule, so drift can only come from a real
// decode/transport stall, never from a rate mismatch. Without forced CFR a
// too-fast assumed rate would make this drop frames forever.
inline AvAction avDecide(int64_t driftMs, int64_t leadMs, int64_t dropMs, int dropRun,
                         int maxDropRun = 1) {
    if (dropMs > 0 && driftMs > dropMs && dropRun < maxDropRun)
        return AvAction::Drop;
    if (driftMs + leadMs < 0)
        return AvAction::Hold;
    return AvAction::Present;
}

// Startup-window simulations (host unit tests).
//
// Silicon (rk=8, 24.000 fps):
//   - Early audio play: audibleClock ~+159..206 ms when frame 1 is ready →
//     pacer Drop/Present massacre (~13 drops) OR, if origin is re-based
//     (co-arm), drops=0 while REAL content offset stays ~+165..206 ms unpaid
//     (grabber −168 → −456 ms, delta −288 ms measured).
//   - Hold-until-video: MrAudio writes start only when frame 1 is ready, so
//     audioHeardContent and videoDisplayedContent share a common wall origin.
//     Drops ~0 AND real content offset ~0 (modulo present lead).
//
// `realOffset` is what the grabber measures (content A − content V). The
// daemon's av_drift_ms is intentionally NOT used as a success criterion here.
enum class StartupAudioMode {
    EarlyPlay,       // audio free-runs before first video; pacer sees raw clock
    CoArmOrigin,     // same physical audio lead; pacer subtracts origin (FAILED on HW)
    HoldUntilVideo,  // audio device starts at first video frame (product fix)
};

struct StartupPacerSim {
    int drops = 0;
    int presents = 0;
    int holds = 0;
    int firstDriftMs = 0; // pacer drift on frame 1 (daemon-visible, can lie)
    int maxDropRun = 0;
    int firstRealOffsetMs = 0;  // content A − content V at first Present
    int lastRealOffsetMs = 0;   // same metric after the window
    int steadyRealOffsetMs = 0; // mean real offset over last half of presents
};

inline StartupPacerSim simulateStartupPacer(int64_t audioMsAtFirstFrame, StartupAudioMode mode,
                                           int frames, int64_t leadMs = 40, int64_t dropMs = 80,
                                           int fpsNum = 24, int fpsDen = 1) {
    StartupPacerSim out{};
    // Physical audio content already heard when frame 1 becomes ready.
    // HoldUntilVideo forces this to 0 (device was gated). Other modes keep it.
    const int64_t audioLeadAtFrame1 =
        (mode == StartupAudioMode::HoldUntilVideo) ? 0 : audioMsAtFirstFrame;
    const int64_t origin =
        (mode == StartupAudioMode::CoArmOrigin) ? audioMsAtFirstFrame : 0;
    int64_t audioHeardContentMs = audioLeadAtFrame1;
    int64_t rawAudioMs = audioLeadAtFrame1; // pacer raw audible clock
    int dropRun = 0;
    int64_t realSum = 0;
    int realN = 0;
    const int64_t framePeriodMs =
        (1000LL * static_cast<int64_t>(fpsDen)) / static_cast<int64_t>(fpsNum > 0 ? fpsNum : 24);
    bool gotFirstPresent = false;
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
            audioHeardContentMs += 2; // device keeps playing during Hold
            clock = coArmedClockMs(rawAudioMs, origin);
            drift = avDriftMs(clock, frameMs);
            act = avDecide(drift, leadMs, dropMs, dropRun);
        }
        if (act == AvAction::Drop) {
            ++out.drops;
            ++dropRun;
            if (dropRun > out.maxDropRun)
                out.maxDropRun = dropRun;
            // Drop: content never reaches display. Audio keeps rolling; next
            // decoded frame arrives in ~one period (no backlog).
        } else {
            ++out.presents;
            dropRun = 0;
            const int64_t realOff = realContentOffsetMs(audioHeardContentMs, frameMs);
            out.lastRealOffsetMs = static_cast<int>(realOff);
            if (!gotFirstPresent) {
                gotFirstPresent = true;
                out.firstRealOffsetMs = static_cast<int>(realOff);
            }
            if (i > frames / 2) {
                realSum += realOff;
                ++realN;
            }
        }
        rawAudioMs += framePeriodMs;
        audioHeardContentMs += framePeriodMs;
    }
    out.steadyRealOffsetMs = realN > 0 ? static_cast<int>(realSum / realN) : out.lastRealOffsetMs;
    return out;
}

// Back-compat wrapper used by older call sites / red twins.
inline StartupPacerSim simulateStartupPacer(int64_t audioMsAtFirstFrame, bool coArm, int frames,
                                           int64_t leadMs = 40, int64_t dropMs = 80,
                                           int fpsNum = 24, int fpsDen = 1) {
    return simulateStartupPacer(audioMsAtFirstFrame,
                                coArm ? StartupAudioMode::CoArmOrigin : StartupAudioMode::EarlyPlay,
                                frames, leadMs, dropMs, fpsNum, fpsDen);
}

// Terminal-signal inventory for the rawvideo read loop. EAGAIN/EWOULDBLOCK is
// deliberately absent: without a known-duration stall, "no bytes right now" is
// indistinguishable from a slow source.
inline bool rawVideoTerminalSignal(bool explicitStopOrSeek, bool readZero, bool readError,
                                   bool shortRead, bool knownDurationStall) {
    return explicitStopOrSeek || readZero || readError || shortRead || knownDurationStall;
}

// For the known-duration EOF stall detector, audio silence is required only when
// the session actually produced audio. Video-only/no-audio-yet sessions use the
// video-silence timer so the detector is not vacuously disabled.
inline int64_t eofStallAudioSilenceMs(bool wantAudio, bool audioSeen, int64_t noVideoMs,
                                      int64_t noAudioMs) {
    return (!wantAudio || !audioSeen) ? noVideoMs : noAudioMs;
}

// A bounded EOF escape for PMS/FFmpeg streams that reach known duration, stop
// producing rawvideo, but leave the pipe open. A partial frame is tolerated only
// after its bytes have also gone stale for the same video-silence grace; otherwise
// slow sources could be truncated mid-frame. Audio progress blocks short stalls
// from being misread as EOF, but not forever: a known-duration video stream with
// no complete decoded frame for 3× grace is treated as terminal even if audio or
// silence keeps trickling.
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
