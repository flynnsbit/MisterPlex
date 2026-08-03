#pragma once
// AUDIO_DELAY_MS → FFmpeg adelay filter, and host-side proofs that the conf
// value becomes real PCM silence at the head of the stream.
//
// Hardware (parent, daemon md5 b981fd20): AUDIO_DELAY_MS=150 moved grabber
// lip-sync by only +33.3 ms. The hypothesis that the pacer / kFeedTargetBytes
// prefill (~100 ms) *cancels* adelay is FALSE in the sample-clock model:
// adelay rearranges content inside the byte stream; audibleClockMs counts
// every PCM byte. See adelayContentShiftMs() and tests/unit/test_audio_delay.cpp.
//
// What remains unaccounted on silicon (~117 ms of a 150 ms request) is NOT
// explained by prefill subtraction or video-slaved-to-audio cancellation.
// The daemon must log the *measured* PCM silence head so a parent run can
// tell "filter never landed in PCM" from "PCM delayed, post-MrAudio ate it".

#include <cstdint>
#include <cstdlib>
#include <string>

namespace misterplex {

// Portable FFmpeg -af chain matching the product cast path.
// Uses per-channel `adelay=N|N` (not `:all=1`) so older FFmpeg builds on the
// MiSTer image accept the filter the same way host unit ladders do.
inline std::string ffmpegAudioDelayFilter(int delayMs) {
    if (delayMs < 0)
        delayMs = 0;
    if (delayMs == 0)
        return "aresample=48000";
    return "aresample=48000,adelay=" + std::to_string(delayMs) + "|" + std::to_string(delayMs);
}

// Model: content lip-sync shift equals conf delay. Prefill / ring depth do not
// cancel content delay (sample clock ≠ content clock). Returns the predicted
// Δ(offset_ms) for a before/after A/B on the same rig.
inline int adelayContentShiftMs(int confDelayMs) {
    if (confDelayMs < 0)
        return 0;
    return confDelayMs;
}

// Explicit kill of the "150 - 100 prefill = 50≈33" story: bytes reserved for
// ring target are still *content* once they drain; they are not subtracted
// from adelay. Always 0 cancelled.
inline int adelayCancelledByPrefillMs(int /*confDelayMs*/, int /*prefillTargetMs*/) { return 0; }

// Leading-silence detector for s16le stereo interleaved PCM.
// Returns milliseconds of head silence, or -1 if samples are null/empty
// (could-not-measure — never silently report 0).
// `threshold` is abs(int16) per mono sample after L/R average; default 500
// matches the host adelay ladder used by tools/avsync_measure_hdmi.py proofs.
inline int64_t pcmSilenceHeadMs(const int16_t* interleavedStereo, int64_t nFrames, int threshold = 500,
                                int sampleRateHz = 48000) {
    if (!interleavedStereo || nFrames <= 0 || sampleRateHz <= 0)
        return -1;
    if (threshold < 0)
        threshold = 0;
    for (int64_t i = 0; i < nFrames; ++i) {
        const int32_t l = interleavedStereo[2 * i];
        const int32_t r = interleavedStereo[2 * i + 1];
        const int32_t mono = (l + r) / 2;
        const int32_t a = mono >= 0 ? mono : -mono;
        if (a > threshold) {
            return (i * 1000LL) / static_cast<int64_t>(sampleRateHz);
        }
    }
    // Entire buffer silent — report full span as measured silence, not -1.
    return (nFrames * 1000LL) / static_cast<int64_t>(sampleRateHz);
}

// Incremental scanner for the audio pump: feed PCM chunks until the first
// non-quiet frame is found. state: framesSeen, done, headMs.
struct SilenceHeadScan {
    int64_t framesSeen = 0;
    bool done = false;
    int64_t headMs = -1; // -1 until done or abandoned
    int threshold = 500;
    int sampleRateHz = 48000;
    // Cap how long we scan so a quiet track does not hold the answer forever.
    int64_t maxScanMs = 2000;

    void reset(int thr = 500, int sr = 48000, int64_t maxMs = 2000) {
        framesSeen = 0;
        done = false;
        headMs = -1;
        threshold = thr;
        sampleRateHz = sr > 0 ? sr : 48000;
        maxScanMs = maxMs > 0 ? maxMs : 2000;
    }

    // data: raw s16le stereo bytes. Returns true when headMs is final.
    bool feed(const void* data, size_t nbytes) {
        if (done || !data || nbytes < 4)
            return done;
        const auto* s = static_cast<const int16_t*>(data);
        const size_t nFrames = nbytes / 4;
        for (size_t i = 0; i < nFrames; ++i) {
            const int32_t l = s[2 * i];
            const int32_t r = s[2 * i + 1];
            const int32_t mono = (l + r) / 2;
            const int32_t a = mono >= 0 ? mono : -mono;
            if (a > threshold) {
                headMs = (framesSeen * 1000LL) / static_cast<int64_t>(sampleRateHz);
                done = true;
                return true;
            }
            ++framesSeen;
            const int64_t elapsedMs =
                (framesSeen * 1000LL) / static_cast<int64_t>(sampleRateHz);
            if (elapsedMs >= maxScanMs) {
                // Still silent through the scan window — report window length.
                headMs = elapsedMs;
                done = true;
                return true;
            }
        }
        return false;
    }
};

} // namespace misterplex
