// Within-run present-path window classification (1 s samples).
// Off-by-default PRESENT_PROFILE emits these; product path unchanged when off.
//
// Hypotheses (parent device-local 480p drops; transport exonerated):
//   H-READ   ffmpeg slow / pipe empty → high eagain sleep, low ddr
//   H-DDR    publish path stalls → high ddr_*_us, may backpressure ffmpeg
//   H-PACER  deliberate avDecide Drop → high drops, supply_ratio may stay ~1
//            if decode keeps up; with shared ffmpeg, slow video can also cut audio
//   H-HOLD   video ahead → high pacing_wait (Hold sleeps)
//   H-MIXED  no single bucket dominates
#pragma once

#include <cstdint>
#include <string>

namespace misterplex {

struct PresentWindowSample {
    int64_t frames = 0;       // fully assembled raw frames (vfps numerator delta)
    int64_t presented = 0;    // presentCleanFrame counted
    int64_t drops = 0;        // avDecide Drop only
    int64_t holds = 0;        // avDecide Hold loop iterations (2ms sleeps)
    int64_t read_eagain = 0;
    int64_t read_sleep_us = 0;
    int64_t read_wall_us = 0;
    int64_t pacing_wait_us = 0;
    int64_t ddr_total_us = 0;
    int64_t ddr_copy_us = 0;
    int64_t ddr_prep_wait_us = 0;
    int64_t ddr_plxd_poll_us = 0;
    int64_t wall_us = 0; // window duration; 0 → NO-DATA
};

enum class PresentWindowClass {
    NoData = 0,
    ReadWait,    // stalled on pipe (EAGAIN sleep dominates)
    DdrBound,     // DDR publish time dominates presented frames
    PacerDrop,   // drops are the main present loss
    HoldWait,    // holding for A/V (video ahead)
    Balanced,    // no single dominant cost
};

inline const char* presentWindowClassName(PresentWindowClass c) {
    switch (c) {
    case PresentWindowClass::ReadWait:
        return "H-READ";
    case PresentWindowClass::DdrBound:
        return "H-DDR";
    case PresentWindowClass::PacerDrop:
        return "H-PACER";
    case PresentWindowClass::HoldWait:
        return "H-HOLD";
    case PresentWindowClass::Balanced:
        return "H-BALANCED";
    default:
        return "NO-DATA";
    }
}

// Classify one window. Thresholds are *relative shares of wall*, not magic bitrates.
// PRE_REG mapping for parent degraded run (supply~0.84, pfps<vfps, drops>0):
//   H-READ:     read_sleep / wall > 0.25 and read_sleep > ddr_total
//   H-DDR:      ddr_total / wall > 0.25 (on presented path cost scaled to wall)
//   H-PACER:    drops/frames > 0.05 and drop gap explains vfps-pfps
//   H-HOLD:     pacing_wait / wall > 0.25
//   else        H-BALANCED
inline PresentWindowClass classifyPresentWindow(const PresentWindowSample& s) {
    if (s.wall_us <= 0 || s.frames < 0)
        return PresentWindowClass::NoData;
    if (s.frames == 0 && s.presented == 0 && s.drops == 0)
        return PresentWindowClass::NoData;

    const double wall = static_cast<double>(s.wall_us);
    const double readShare = static_cast<double>(s.read_sleep_us) / wall;
    const double holdShare = static_cast<double>(s.pacing_wait_us) / wall;
    // DDR cost is only paid on present; compare to wall for backpressure budget.
    const double ddrShare = static_cast<double>(s.ddr_total_us) / wall;
    const double dropFrac =
        s.frames > 0 ? static_cast<double>(s.drops) / static_cast<double>(s.frames) : 0.0;

    // Pick the largest actionable signal above threshold.
    PresentWindowClass best = PresentWindowClass::Balanced;
    double bestScore = 0.0;
    auto consider = [&](PresentWindowClass c, double score, double thr) {
        if (score >= thr && score > bestScore) {
            bestScore = score;
            best = c;
        }
    };
    consider(PresentWindowClass::ReadWait, readShare, 0.25);
    consider(PresentWindowClass::HoldWait, holdShare, 0.25);
    consider(PresentWindowClass::DdrBound, ddrShare, 0.25);
    // Pacer: fraction of frames dropped; 5% is already user-visible.
    consider(PresentWindowClass::PacerDrop, dropFrac, 0.05);
    return best;
}

inline std::string formatPresentWindowLine(const PresentWindowSample& s, int64_t wall_s_i,
                                           int64_t cum_drops, int64_t av_drift_ms) {
    const auto cls = classifyPresentWindow(s);
    auto avg = [](int64_t us, int64_t n) -> int64_t {
        return n > 0 ? us / n : 0;
    };
    const int64_t n = s.frames > 0 ? s.frames : 0;
    const int64_t np = s.presented > 0 ? s.presented : 0;
    std::string o = "media: present_window wall_s=";
    o += std::to_string(wall_s_i);
    o += " class=";
    o += presentWindowClassName(cls);
    o += " d_frames=";
    o += std::to_string(s.frames);
    o += " d_presented=";
    o += std::to_string(s.presented);
    o += " d_drops=";
    o += std::to_string(s.drops);
    o += " d_holds=";
    o += std::to_string(s.holds);
    o += " cum_drops=";
    o += std::to_string(cum_drops);
    o += " av_drift_ms=";
    o += std::to_string(av_drift_ms);
    o += " read_sleep_us_f=";
    o += std::to_string(avg(s.read_sleep_us, n));
    o += " read_wall_us_f=";
    o += std::to_string(avg(s.read_wall_us, n));
    o += " read_eagain_f=";
    o += std::to_string(n > 0 ? s.read_eagain / n : 0);
    o += " pacing_wait_us_f=";
    o += std::to_string(avg(s.pacing_wait_us, n));
    o += " ddr_total_us_p=";
    o += std::to_string(avg(s.ddr_total_us, np));
    o += " ddr_copy_us_p=";
    o += std::to_string(avg(s.ddr_copy_us, np));
    o += " ddr_prep_wait_us_p=";
    o += std::to_string(avg(s.ddr_prep_wait_us, np));
    o += " ddr_plxd_poll_us_p=";
    o += std::to_string(avg(s.ddr_plxd_poll_us, np));
    o += " wall_us=";
    o += std::to_string(s.wall_us);
    return o;
}

// supply_ratio semantics (audio_s/wall_s) for parent question:
// Audio pump wall-paces after each PCM chunk and reads the same ffmpeg process
// as video. A stalled video reader that backpressures ffmpeg stdout also stalls
// audio encode → supply_ratio < 1. A pure pacer Drop while still reading 24fps
// leaves ffmpeg busy → supply_ratio ≈ 1. So supply_ratio=0.837 is compatible
// with (a) decode/scale CPU limit and (b) present/DDR backpressure into ffmpeg,
// and NOT with pure pacer-only loss at full decode rate.
inline const char* supplyRatioImplies(double supply_ratio, double vfps, double content_fps) {
    if (!(supply_ratio > 0.0) || !(vfps > 0.0) || !(content_fps > 0.0))
        return "NO-DATA";
    // Production rate ≈ vfps; content expects content_fps.
    const double prod = vfps / content_fps;
    // If supply tracks production, shared ffmpeg throttle.
    if (supply_ratio < 0.95 && prod < 0.95)
        return "SHARED_FFMPEG_THROTTLE"; // decode or backpressure — not pacer-only
    if (supply_ratio >= 0.95 && prod >= 0.95)
        return "FULL_RATE_SUPPLY";
    if (supply_ratio >= 0.95 && prod < 0.95)
        return "VIDEO_SLOW_AUDIO_OK"; // unusual with single ffmpeg
    if (supply_ratio < 0.95 && prod >= 0.95)
        return "AUDIO_SLOW_VIDEO_OK"; // audio path alone
    return "MIXED";
}

} // namespace misterplex
