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

// Terminal-signal inventory for the rawvideo read loop. EAGAIN/EWOULDBLOCK is
// deliberately absent: without a known-duration stall, "no bytes right now" is
// indistinguishable from a slow source.
inline bool rawVideoTerminalSignal(bool explicitStopOrSeek, bool readZero, bool readError,
                                   bool shortRead, bool knownDurationStall) {
    return explicitStopOrSeek || readZero || readError || shortRead || knownDurationStall;
}

// A bounded EOF escape for PMS/FFmpeg streams that reach known duration, stop
// producing rawvideo, but leave the pipe open. Only fire with no partial frame:
// a partial frame is treated as a real short-read so diagnostics can report it.
inline bool knownDurationEofStall(int64_t startMs, int64_t durationMs, int64_t elapsedMs,
                                  int64_t partialFrameBytes, int64_t noVideoMs,
                                  int64_t graceMs = 5000) {
    if (durationMs <= 0 || elapsedMs < 0 || partialFrameBytes != 0)
        return false;
    if (graceMs < 0)
        graceMs = 0;
    return startMs + elapsedMs >= durationMs + graceMs && noVideoMs >= graceMs;
}

} // namespace misterplex
