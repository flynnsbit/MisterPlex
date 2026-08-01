#pragma once
// Parse the status line exposed by MiSTer's MrAudio driver.
//
// /dev/MrAudio is a 512 KB DMA ring (sound/drivers/MiSTer-audio-spi.c). Its
// write path NEVER blocks and never consults the read pointer — it just copies
// into the ring and wraps. Two consequences drive this file:
//
//   1. write() returning tells you NOTHING about playback. Measured on the lab
//      unit, 10 s of PCM is accepted in 116 ms. So a clock built from bytes
//      *submitted* runs ahead of the audio you actually hear, which is why the
//      video used to need a hand-tuned delay to compensate.
//   2. Because there is no backpressure, feeding faster than realtime silently
//      overwrites audio that has not been played yet. Nothing reports this.
//
// The driver's open() handler does an spi_read of the FPGA's read pointer and
// formats one line:
//
//     rptr: 234576, wptr: 234576, len:      0, comp: 0
//
// `len` is (wptr - rptr) wrapped — bytes queued but not yet played, i.e. the
// output latency in bytes. Reading it turns the submitted-byte counter into a
// real playback position, and makes the overwrite case observable.

#include <cstdint>

namespace misterplex {

// s16le stereo @ 48 kHz — the only format the pump feeds.
constexpr int64_t kMrAudioBytesPerSec = 48000LL * 4LL;

// Size of the driver's DMA ring (BUFFER_LEN). Anything at or beyond this is
// nonsense and means we misparsed.
constexpr int64_t kMrAudioRingBytes = 512LL * 1024LL;

// Pull an unsigned decimal field after `key` (e.g. "len:", "rptr:").
// Returns value, or -1 if absent/malformed. Caps at `maxInclusive` (use ring
// size for len; large for pointers).
inline int64_t parseMrAudioUField(const char* s, int64_t n, const char* key, int64_t maxInclusive) {
    if (!s || n <= 0 || !key || maxInclusive < 0)
        return -1;
    int64_t keyLen = 0;
    while (key[keyLen] != '\0')
        ++keyLen;
    if (keyLen <= 0 || keyLen > n)
        return -1;
    for (int64_t i = 0; i + keyLen <= n; ++i) {
        bool hit = true;
        for (int64_t k = 0; k < keyLen; ++k) {
            if (s[i + k] != key[k]) {
                hit = false;
                break;
            }
        }
        if (!hit)
            continue;
        int64_t j = i + keyLen;
        while (j < n && (s[j] == ' ' || s[j] == '\t'))
            ++j;
        if (j >= n || s[j] < '0' || s[j] > '9')
            return -1;
        int64_t v = 0;
        while (j < n && s[j] >= '0' && s[j] <= '9') {
            v = v * 10 + (s[j] - '0');
            if (v > maxInclusive)
                return -1;
            ++j;
        }
        return v;
    }
    return -1;
}

// Pull the `len:` field out of the driver's status line.
// Returns bytes queued, or -1 if the line is absent/malformed/out of range.
// Deliberately hand-rolled: this parses a kernel string on a hot path and must
// not throw, allocate, or depend on locale.
inline int64_t parseMrAudioQueuedBytes(const char* s, int64_t n) {
    const int64_t v = parseMrAudioUField(s, n, "len:", kMrAudioRingBytes);
    return (v < 0 || v >= kMrAudioRingBytes) ? -1 : v;
}

// Full status snapshot for handoff instrumentation (open / first-write).
// Pointers are driver/FPGA units as printed; -1 = not parsed.
// Observability ENDS at this sample: FPGA drain phase beyond len is not here.
struct MrAudioStatusSnap {
    int64_t rptr = -1;
    int64_t wptr = -1;
    int64_t len = -1;
    int64_t comp = -1;
    bool ok = false;
};

inline MrAudioStatusSnap parseMrAudioStatusSnap(const char* s, int64_t n) {
    MrAudioStatusSnap out{};
    if (!s || n <= 0)
        return out;
    // Pointers can equal BUFFER_LEN-ish; allow up to 2× ring as sanity (not a claim).
    constexpr int64_t kPtrMax = kMrAudioRingBytes * 2;
    out.rptr = parseMrAudioUField(s, n, "rptr:", kPtrMax);
    out.wptr = parseMrAudioUField(s, n, "wptr:", kPtrMax);
    out.len = parseMrAudioQueuedBytes(s, n);
    out.comp = parseMrAudioUField(s, n, "comp:", 1024);
    out.ok = (out.len >= 0);
    return out;
}

// Audible playback position (ms) = what we handed the driver, minus what is
// still sitting in the ring. `queuedBytes` < 0 means "unknown", in which case we
// fall back to the submitted-byte clock so a kernel without this line still
// plays (just with the old hand-tuned offset).
inline int64_t audibleClockMs(int64_t writtenBytes, int64_t queuedBytes) {
    int64_t played = writtenBytes;
    if (queuedBytes >= 0)
        played -= queuedBytes;
    if (played <= 0)
        return 0;
    return (played * 1000LL) / kMrAudioBytesPerSec;
}

// ---------------------------------------------------------------------------
// Feed-rate servo
// ---------------------------------------------------------------------------
//
// The ring has no backpressure, so nothing stops the pump from feeding faster
// (or slower) than the FPGA actually plays. Any mismatch integrates directly
// into the ring depth: measured on the lab unit, an open-loop feed trimmed by
// AUDIO_CLOCK_PPM=+685 grew the ring by ~255 B/s (~1330 ppm too fast), i.e.
// ~80 ms/min, which overruns the 512 KB ring roughly 30 minutes into a
// 45-minute episode and silently shreds unplayed audio.
//
// That constant was not wrong through carelessness: it was measured over HDMI
// capture back when video paced off *submitted* bytes, so a growing ring was
// indistinguishable from a fast playback clock. The two only separate once the
// read pointer is visible.
//
// So do not trim the feed with a constant at all. The ring depth IS the error
// signal: hold it at a target by adjusting the feed rate. Depth is the integral
// of (feed - drain), so proportional control here is a stable first-order loop
// with time constant kFeedServoTauSec and no steady-state error in *rate* (the
// residual appears as a small constant depth offset, which is harmless — only
// its stability matters, because the audible clock subtracts it anyway).
//
// This also removes the per-board calibration: whatever the real audio clock
// is, the loop finds it.

// Ring depth the servo aims to hold, in bytes (~100 ms). Big enough to ride out
// scheduler jitter on a 20 ms chunk cadence, small enough that a pause or seek
// does not leave a long tail of stale audio to flush.
inline constexpr int64_t kFeedTargetBytes = kMrAudioBytesPerSec / 10;

// Loop time constant, seconds. A depth error decays with roughly this time
// constant.
inline constexpr double kFeedServoTauSec = 8.0;

// Hard limit on how far the servo may bend the feed rate, as a fraction. 1% is
// ~10000 ppm — an order of magnitude beyond any plausible crystal error, so it
// only engages while draining a startup burst, and it bounds the damage if a
// depth reading is ever garbage.
inline constexpr double kFeedServoMaxFrac = 0.01;

// Feed rate (bytes/sec) for the next chunk.
//   nominalBytesPerSec - 48 kHz stereo s16le, optionally pre-trimmed by
//                        AUDIO_CLOCK_PPM (now only a seed; the loop converges
//                        from any sane starting point).
//   queuedBytes        - smoothed ring depth, or < 0 if unknown.
// With an unknown depth the servo disengages and the caller gets the open-loop
// rate, preserving the old behaviour on a kernel lacking the status line.
inline double feedRateBytesPerSec(double nominalBytesPerSec, int64_t queuedBytes) {
    if (queuedBytes < 0)
        return nominalBytesPerSec;
    const double err = static_cast<double>(queuedBytes - kFeedTargetBytes);
    double corr = -err / kFeedServoTauSec;
    const double lim = nominalBytesPerSec * kFeedServoMaxFrac;
    if (corr > lim)
        corr = lim;
    if (corr < -lim)
        corr = -lim;
    const double r = nominalBytesPerSec + corr;
    return r < 1.0 ? 1.0 : r;
}

} // namespace misterplex
