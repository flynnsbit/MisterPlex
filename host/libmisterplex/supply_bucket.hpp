// Per-second supply ledger + ffmpeg frame= parse (glass-loss PRE vs POST split).
//
// Parent hard result: 22 display-side skips / 1429 source frames with
// residual=0 publish_misses=0 — daemon residual is blind to ≥14 of them.
// Survivors: PRE-frameIndex supply OR POST-present scanout.
//
// This header is host-pure (unit-tested). Arm emits the strings; parent scores.
//
// CAN distinguish (when ffmpeg_out_frames is measured):
//   PRE-ffmpeg (PMS/transcode/decode short):  ffmpeg_out << wall×fps, frames≈ffmpeg_out
//   pipe/read short (ffmpeg→daemon):          frames << ffmpeg_out, bytes identity fails or gap
//   POST-present (ARM published, glass miss): wall gap≈0, frames≈ffmpeg_out≈expected, residual 0
//
// CANNOT distinguish with this alone:
//   which POST-present substage (DDR bank vs RTL scanout vs HDMI PHY)
//   grabber drop (parent killed via 24/30 ratio; not this tool's job)
//
// Rule 0: every field tagged measured | caller_supplied | derived | NO-DATA.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

// Locked absolute thresholds (same as analyze_glass480_stage.py) — 1 frame res.
inline constexpr int64_t kSupplyGapFlatFrames = 2;
inline constexpr int64_t kSupplyGapHitFrames = 10;

struct SupplyCounters {
    int64_t frames = 0;           // pipe assemblies = frameIndex
    int64_t presents = 0;
    int64_t drops = 0;
    int64_t publish_misses = 0;
    int64_t pipe_bytes = 0;       // cumulative raw read
    int64_t ffmpeg_out_frames = -1; // -1 = NO-DATA
    double wall_s = 0;
};

struct SupplyBucketDelta {
    double d_wall_s = 0;
    int64_t d_frames = 0;
    int64_t d_presents = 0;
    int64_t d_drops = 0;
    int64_t d_publish_misses = 0;
    // Supply residual delta: Δ(frames-presents-drops). ARM-only; not FPGA.
    int64_t d_residual = 0;
    int64_t d_pipe_bytes = 0;
    int64_t d_ffmpeg_out = -1; // -1 if either endpoint NO-DATA
    double expected_frames = 0;
    double supply_gap = 0; // expected - d_frames (only valid when gap_scored)
    bool ffmpeg_out_known = false;
    bool gap_scored = true; // false → supply_gap must not be used as a measurement
    const char* gap_score_tag = "scored"; // scored | refused_* | NO-DATA
};

// Pace rate provenance for supply_bucket / status lines (ERROR 17 class).
// "caller_supplied" is NOT a measurement — only "measured" is banner-derived.
inline const char* supplyFpsSrcName(bool measured, bool caller_set) {
    if (measured)
        return "measured";
    if (caller_set)
        return "caller_supplied";
    return "DEFAULT_ASSUMED";
}

// Line-level tag = WEAKEST input (w-instr ERROR 17 discipline).
// Rank: measured (strongest) > caller_supplied > DEFAULT_ASSUMED > NO-DATA (weakest).
// A line that mixes measured counters with an assumed rate must NOT say tag=measured.
inline int provenanceRank(const char* tag) {
    if (!tag || !tag[0])
        return 0;
    if (std::strcmp(tag, "measured") == 0)
        return 3;
    if (std::strcmp(tag, "caller_supplied") == 0)
        return 2;
    if (std::strcmp(tag, "DEFAULT_ASSUMED") == 0)
        return 1;
    return 0; // NO-DATA / unknown / refused_*
}

inline const char* weakestProvenanceTag(const char* a, const char* b) {
    const int ra = provenanceRank(a);
    const int rb = provenanceRank(b);
    if (ra == 0 && rb == 0)
        return (a && a[0]) ? a : ((b && b[0]) ? b : "NO-DATA");
    if (ra == 0)
        return (a && a[0]) ? a : (b ? b : "NO-DATA");
    if (rb == 0)
        return (b && b[0]) ? b : (a ? a : "NO-DATA");
    return (ra <= rb) ? (a ? a : "NO-DATA") : (b ? b : "NO-DATA");
}

// Gap fields inherit the rate provenance used to compute them. Refused → NO-DATA.
inline const char* gapScoreAsProvenance(bool gap_scored, const char* fps_src) {
    if (!gap_scored)
        return "NO-DATA";
    return (fps_src && fps_src[0]) ? fps_src : "NO-DATA";
}

// |a-b| in fps units; rationals with den<=0 rejected.
inline bool supplyFpsRationalsAgree(int n1, int d1, int n2, int d2, double maxAbsFps = 0.51) {
    if (n1 <= 0 || d1 <= 0 || n2 <= 0 || d2 <= 0)
        return false;
    const double a = static_cast<double>(n1) / static_cast<double>(d1);
    const double b = static_cast<double>(n2) / static_cast<double>(d2);
    return std::fabs(a - b) <= maxAbsFps;
}

// Decide whether expected_frames/supply_gap may be scored.
// Refuse when pace is DEFAULT_ASSUMED and a measured banner rate disagrees (ERROR 17).
// Also refuse when caller_supplied pace disagrees with measured banner.
// When pace is measured, always score. When DEFAULT_ASSUMED and no measured yet,
// refuse (do not silently score against 24).
struct SupplyGapScoreDecision {
    bool score = false;
    const char* tag = "NO-DATA";
};

inline SupplyGapScoreDecision decideSupplyGapScore(const char* fps_src, bool have_measured,
                                                   int pace_n, int pace_d, int meas_n,
                                                   int meas_d) {
    SupplyGapScoreDecision r;
    if (!fps_src)
        fps_src = "NO-DATA";
    if (std::strcmp(fps_src, "measured") == 0) {
        r.score = (pace_n > 0 && pace_d > 0);
        r.tag = r.score ? "scored" : "NO-DATA";
        return r;
    }
    if (std::strcmp(fps_src, "caller_supplied") == 0) {
        if (have_measured && !supplyFpsRationalsAgree(pace_n, pace_d, meas_n, meas_d)) {
            r.score = false;
            r.tag = "refused_caller_vs_measured";
            return r;
        }
        r.score = (pace_n > 0 && pace_d > 0);
        r.tag = r.score ? "scored" : "NO-DATA";
        return r;
    }
    // DEFAULT_ASSUMED
    if (!have_measured) {
        r.score = false;
        r.tag = "refused_assumed_unverified";
        return r;
    }
    if (!supplyFpsRationalsAgree(pace_n, pace_d, meas_n, meas_d)) {
        r.score = false;
        r.tag = "refused_assumed_vs_measured";
        return r;
    }
    // Assumed 24 matched measured banner — still label fps_src as measured at call site
    // when scoring against the banner rate. Here pace agrees: allow score.
    r.score = true;
    r.tag = "scored_assumed_matches_measured";
    return r;
}

// --- Link/arrival real-time ratio (parent 480p drop RCA 2026-08-01) ---
//
// Derivation (fields already on media: lines):
//   audio_s = audioBytes / (48000 * 4)     // AAC→PCM media seconds written
//   wall_s  = wall_ms / 1000               // steady playback wall
//   supply_ratio = audio_s / wall_s        // media seconds arrived per wall second
//
// Parent controlled intervention on same clip/link:
//   collapse @2000k: audio_s/wall_s ≈ 0.467  (STARVED)
//   healthy  @1000k: audio_s/wall_s ≈ 0.993  (OK)
// Recv-Q EMPTY on collapse ⇒ not pipe back-pressure; this ratio is the observable.
//
// Thresholds locked to those measurements (not guessed fps):
inline constexpr double kSupplyRealtimeStarvedLt = 0.85; // < → STARVED (wall≥min)
inline constexpr double kSupplyRealtimeOkGe = 0.95;      // ≥ → OK
inline constexpr double kSupplyRealtimeMinWallS = 5.0;   // below → WARMUP (ratio still printed)

struct SupplyRealtime {
    double ratio = 0.0;
    bool ratio_known = false;
    // STARVED | MARGINAL | OK | WARMUP | NO-DATA
    const char* class_name = "NO-DATA";
    // Always the same derivation string for greppability.
    const char* der = "audio_s/wall_s";
};

inline SupplyRealtime classifySupplyRealtime(double audio_s, double wall_s) {
    SupplyRealtime r;
    if (!(wall_s > 0.0) || !(audio_s >= 0.0) || !std::isfinite(audio_s) ||
        !std::isfinite(wall_s)) {
        r.ratio_known = false;
        r.class_name = "NO-DATA";
        return r;
    }
    r.ratio = audio_s / wall_s;
    r.ratio_known = std::isfinite(r.ratio);
    if (!r.ratio_known) {
        r.class_name = "NO-DATA";
        return r;
    }
    if (wall_s < kSupplyRealtimeMinWallS) {
        r.class_name = "WARMUP";
        return r;
    }
    if (r.ratio < kSupplyRealtimeStarvedLt)
        r.class_name = "STARVED";
    else if (r.ratio >= kSupplyRealtimeOkGe)
        r.class_name = "OK";
    else
        r.class_name = "MARGINAL";
    return r;
}

// Format fields for media: line (no leading space). ratio=NO-DATA when unknown.
inline std::string formatSupplyRealtimeFields(const SupplyRealtime& r) {
    char buf[192];
    if (!r.ratio_known) {
        std::snprintf(buf, sizeof(buf),
                      "supply_ratio=NO-DATA supply_class=%s supply_ratio_der=%s",
                      r.class_name ? r.class_name : "NO-DATA",
                      r.der ? r.der : "audio_s/wall_s");
    } else {
        std::snprintf(buf, sizeof(buf),
                      "supply_ratio=%.3f supply_class=%s supply_ratio_der=%s", r.ratio,
                      r.class_name ? r.class_name : "NO-DATA",
                      r.der ? r.der : "audio_s/wall_s");
    }
    return std::string(buf);
}

// residual = frames - presents - drops (supply-side arithmetic only).
inline int64_t supplyResidual(int64_t frames, int64_t presents, int64_t drops) {
    return frames - presents - drops;
}
// Deprecated alias — same derivation as supplyResidual.
inline int64_t supplyUnaccounted(int64_t frames, int64_t presents, int64_t drops) {
    return supplyResidual(frames, presents, drops);
}

inline SupplyBucketDelta supplyBucketDelta(const SupplyCounters& a, const SupplyCounters& b,
                                           int fpsNum, int fpsDen) {
    SupplyBucketDelta d;
    d.d_wall_s = b.wall_s - a.wall_s;
    d.d_frames = b.frames - a.frames;
    d.d_presents = b.presents - a.presents;
    d.d_drops = b.drops - a.drops;
    d.d_publish_misses = b.publish_misses - a.publish_misses;
    d.d_pipe_bytes = b.pipe_bytes - a.pipe_bytes;
    const int64_t ua = supplyResidual(a.frames, a.presents, a.drops);
    const int64_t ub = supplyResidual(b.frames, b.presents, b.drops);
    d.d_residual = ub - ua;
    if (fpsNum <= 0)
        fpsNum = 24;
    if (fpsDen <= 0)
        fpsDen = 1;
    d.expected_frames = d.d_wall_s * static_cast<double>(fpsNum) / static_cast<double>(fpsDen);
    d.supply_gap = d.expected_frames - static_cast<double>(d.d_frames);
    if (a.ffmpeg_out_frames >= 0 && b.ffmpeg_out_frames >= 0) {
        d.d_ffmpeg_out = b.ffmpeg_out_frames - a.ffmpeg_out_frames;
        d.ffmpeg_out_known = true;
    } else {
        d.d_ffmpeg_out = -1;
        d.ffmpeg_out_known = false;
    }
    return d;
}

// Parse ffmpeg -stats / -progress line for frame count.
// Accepts: "frame=123", "frame=  123", "frame=123 fps=..."
inline bool parseFfmpegFrameCountLine(const char* line, int64_t* outFrames) {
    if (!line || !outFrames)
        return false;
    const char* p = std::strstr(line, "frame=");
    if (!p)
        return false;
    p += 6;
    while (*p == ' ' || *p == '\t')
        ++p;
    if (*p < '0' || *p > '9')
        return false;
    int64_t v = 0;
    while (*p >= '0' && *p <= '9') {
        v = v * 10 + (*p - '0');
        ++p;
    }
    *outFrames = v;
    return true;
}

inline bool parseFfmpegFrameCountLine(const std::string& line, int64_t* outFrames) {
    return parseFfmpegFrameCountLine(line.c_str(), outFrames);
}

// ffmpeg -stats rewrites the progress line with '\r' (no '\n') until exit.
// A pump that only splits on '\n' leaves frame= stuck at NO-DATA for the soak.
// Returns true when one logical line was taken from the front of acc.
inline bool takeFfmpegStderrLine(std::string& acc, std::string* outLine) {
    if (!outLine)
        return false;
    const auto npos = acc.find('\n');
    const auto rpos = acc.find('\r');
    if (npos == std::string::npos && rpos == std::string::npos)
        return false;
    size_t pos = 0;
    if (npos != std::string::npos && (rpos == std::string::npos || npos <= rpos)) {
        pos = npos;
        *outLine = acc.substr(0, pos);
        acc.erase(0, pos + 1);
    } else {
        pos = rpos;
        *outLine = acc.substr(0, pos);
        acc.erase(0, pos + 1);
        // Treat CRLF as one separator.
        if (!acc.empty() && acc[0] == '\n')
            acc.erase(0, 1);
    }
    while (!outLine->empty() &&
           (outLine->back() == '\r' || outLine->back() == '\n' || outLine->back() == ' '))
        outLine->pop_back();
    return true;
}

// Apply gap-score decision onto a delta (zeros gap fields when refused).
inline void applySupplyGapScore(SupplyBucketDelta& d, const SupplyGapScoreDecision& dec) {
    d.gap_scored = dec.score;
    d.gap_score_tag = dec.tag ? dec.tag : "NO-DATA";
    if (!dec.score) {
        d.expected_frames = 0;
        d.supply_gap = 0;
    }
}

// Teardown: bytes ↔ frameIndex identity when aligned.
struct SupplyPipeIdentity {
    bool byte_aligned = false;
    int64_t frames_from_bytes = 0; // total_bytes / frame_bytes when aligned
    int64_t remainder = 0;
    int64_t frame_index = 0;
    int64_t delta_frames_vs_bytes = 0; // frame_index - frames_from_bytes
    bool ok = false;                  // aligned and counts match
};

inline SupplyPipeIdentity supplyPipeIdentity(size_t totalBytes, size_t frameBytes,
                                             int64_t frameIndex) {
    SupplyPipeIdentity id;
    id.frame_index = frameIndex;
    if (frameBytes == 0) {
        id.byte_aligned = false;
        id.remainder = static_cast<int64_t>(totalBytes);
        id.ok = false;
        return id;
    }
    id.remainder = static_cast<int64_t>(totalBytes % frameBytes);
    id.byte_aligned = (id.remainder == 0);
    id.frames_from_bytes = static_cast<int64_t>(totalBytes / frameBytes);
    id.delta_frames_vs_bytes = frameIndex - id.frames_from_bytes;
    id.ok = id.byte_aligned && id.delta_frames_vs_bytes == 0;
    return id;
}

// Stage hint from one bucket (or whole-window delta). glass_holes caller_supplied.
// Returns stable string stage id.
inline const char* supplyStageHint(const SupplyBucketDelta& d, int64_t glassHoles,
                                   bool pipeFail) {
    if (pipeFail)
        return "PIPE";
    if (glassHoles < 3)
        return "NO_GLASS_LOSS";
    const bool hostFlat = d.d_residual <= kSupplyGapFlatFrames &&
                          d.d_publish_misses <= kSupplyGapFlatFrames;
    const bool supplyHit = d.supply_gap >= static_cast<double>(kSupplyGapHitFrames);
    const bool supplyFlat = d.supply_gap <= static_cast<double>(kSupplyGapFlatFrames);
    if (!hostFlat && d.d_residual >= kSupplyGapHitFrames)
        return "HOST_MID";
    if (d.ffmpeg_out_known) {
        const double ffGap = d.expected_frames - static_cast<double>(d.d_ffmpeg_out);
        const int64_t pipeVsFf = d.d_frames - d.d_ffmpeg_out; // neg ⇒ read less than ffmpeg wrote
        if (ffGap >= static_cast<double>(kSupplyGapHitFrames) && hostFlat &&
            (d.d_frames - d.d_ffmpeg_out) >= -kSupplyGapFlatFrames &&
            (d.d_frames - d.d_ffmpeg_out) <= kSupplyGapFlatFrames)
            return "PRE_FFMPEG_SUPPLY"; // ffmpeg itself short vs wall schedule
        if (d.d_ffmpeg_out - d.d_frames >= kSupplyGapHitFrames && hostFlat)
            return "PIPE_READ_SHORT"; // ffmpeg produced more than we assembled
        if (supplyFlat && hostFlat && ffGap <= static_cast<double>(kSupplyGapFlatFrames) &&
            pipeVsFf >= -kSupplyGapFlatFrames && pipeVsFf <= kSupplyGapFlatFrames)
            return "POST_PRESENT_SCANOUT";
    }
    if (supplyHit && hostFlat)
        return "PRE_FRAMEINDEX_SUPPLY"; // wall gap only (ffmpeg_out NO-DATA or unused)
    if (supplyFlat && hostFlat)
        return "POST_PRESENT_SCANOUT";
    return "AMBIGUOUS";
}

// Telemetry line (no leading media: prefix — caller adds).
// fps_src must be measured|caller_supplied|DEFAULT_ASSUMED (never hardcode).
// When !d.gap_scored, expected_frames/supply_gap print as NO-DATA (refuse-to-score).
// Line tag= is WEAKEST of fps_src and gap provenance — never blanket "measured".
inline std::string formatSupplyBucketLine(const SupplyBucketDelta& d, double wall_s,
                                          int64_t frames, int64_t presents, int64_t drops,
                                          int64_t publishMisses, int64_t residual,
                                          int64_t ffmpegOut, int fpsNum, int fpsDen,
                                          const char* sessionEpoch, const char* fpsSrc) {
    char buf[896];
    const char* src = (fpsSrc && fpsSrc[0]) ? fpsSrc : "NO-DATA";
    const char* gapTag = d.gap_score_tag ? d.gap_score_tag : "NO-DATA";
    // Counters (d_frames etc.) are measured; rate-derived fields follow fps_src/gap.
    const char* lineTag =
        weakestProvenanceTag(src, gapScoreAsProvenance(d.gap_scored, src));
    if (ffmpegOut >= 0) {
        if (d.gap_scored) {
            std::snprintf(
                buf, sizeof(buf),
                "supply_bucket wall_s=%.3f d_wall_s=%.3f d_frames=%lld d_presents=%lld "
                "d_drops=%lld d_publish_misses=%lld d_residual=%lld "
                "d_residual_eq=frames-presents-drops residual_scope=supply_arm_only "
                "d_pipe_bytes=%lld expected_frames=%.3f supply_gap=%.3f gap_score=%s "
                "d_ffmpeg_out=%lld "
                "ffmpeg_out_frames=%lld frames=%lld presents=%lld drops=%lld "
                "publish_misses=%lld residual=%lld residual_eq=frames-presents-drops "
                "fps=%d/%d fps_src=%s session_epoch=%s fpga_obs=none tag=%s",
                wall_s, d.d_wall_s, static_cast<long long>(d.d_frames),
                static_cast<long long>(d.d_presents), static_cast<long long>(d.d_drops),
                static_cast<long long>(d.d_publish_misses),
                static_cast<long long>(d.d_residual),
                static_cast<long long>(d.d_pipe_bytes), d.expected_frames, d.supply_gap, gapTag,
                static_cast<long long>(d.d_ffmpeg_out), static_cast<long long>(ffmpegOut),
                static_cast<long long>(frames), static_cast<long long>(presents),
                static_cast<long long>(drops), static_cast<long long>(publishMisses),
                static_cast<long long>(residual), fpsNum, fpsDen, src,
                sessionEpoch ? sessionEpoch : "NO-DATA", lineTag);
        } else {
            std::snprintf(
                buf, sizeof(buf),
                "supply_bucket wall_s=%.3f d_wall_s=%.3f d_frames=%lld d_presents=%lld "
                "d_drops=%lld d_publish_misses=%lld d_residual=%lld "
                "d_residual_eq=frames-presents-drops residual_scope=supply_arm_only "
                "d_pipe_bytes=%lld expected_frames=NO-DATA supply_gap=NO-DATA gap_score=%s "
                "d_ffmpeg_out=%lld "
                "ffmpeg_out_frames=%lld frames=%lld presents=%lld drops=%lld "
                "publish_misses=%lld residual=%lld residual_eq=frames-presents-drops "
                "fps=%d/%d fps_src=%s session_epoch=%s fpga_obs=none tag=%s",
                wall_s, d.d_wall_s, static_cast<long long>(d.d_frames),
                static_cast<long long>(d.d_presents), static_cast<long long>(d.d_drops),
                static_cast<long long>(d.d_publish_misses),
                static_cast<long long>(d.d_residual),
                static_cast<long long>(d.d_pipe_bytes), gapTag,
                static_cast<long long>(d.d_ffmpeg_out), static_cast<long long>(ffmpegOut),
                static_cast<long long>(frames), static_cast<long long>(presents),
                static_cast<long long>(drops), static_cast<long long>(publishMisses),
                static_cast<long long>(residual), fpsNum, fpsDen, src,
                sessionEpoch ? sessionEpoch : "NO-DATA", lineTag);
        }
    } else {
        if (d.gap_scored) {
            std::snprintf(
                buf, sizeof(buf),
                "supply_bucket wall_s=%.3f d_wall_s=%.3f d_frames=%lld d_presents=%lld "
                "d_drops=%lld d_publish_misses=%lld d_residual=%lld "
                "d_residual_eq=frames-presents-drops residual_scope=supply_arm_only "
                "d_pipe_bytes=%lld expected_frames=%.3f supply_gap=%.3f gap_score=%s "
                "d_ffmpeg_out=NO-DATA "
                "ffmpeg_out_frames=NO-DATA frames=%lld presents=%lld drops=%lld "
                "publish_misses=%lld residual=%lld residual_eq=frames-presents-drops "
                "fps=%d/%d fps_src=%s session_epoch=%s fpga_obs=none tag=%s",
                wall_s, d.d_wall_s, static_cast<long long>(d.d_frames),
                static_cast<long long>(d.d_presents), static_cast<long long>(d.d_drops),
                static_cast<long long>(d.d_publish_misses),
                static_cast<long long>(d.d_residual),
                static_cast<long long>(d.d_pipe_bytes), d.expected_frames, d.supply_gap, gapTag,
                static_cast<long long>(frames), static_cast<long long>(presents),
                static_cast<long long>(drops), static_cast<long long>(publishMisses),
                static_cast<long long>(residual), fpsNum, fpsDen, src,
                sessionEpoch ? sessionEpoch : "NO-DATA", lineTag);
        } else {
            std::snprintf(
                buf, sizeof(buf),
                "supply_bucket wall_s=%.3f d_wall_s=%.3f d_frames=%lld d_presents=%lld "
                "d_drops=%lld d_publish_misses=%lld d_residual=%lld "
                "d_residual_eq=frames-presents-drops residual_scope=supply_arm_only "
                "d_pipe_bytes=%lld expected_frames=NO-DATA supply_gap=NO-DATA gap_score=%s "
                "d_ffmpeg_out=NO-DATA "
                "ffmpeg_out_frames=NO-DATA frames=%lld presents=%lld drops=%lld "
                "publish_misses=%lld residual=%lld residual_eq=frames-presents-drops "
                "fps=%d/%d fps_src=%s session_epoch=%s fpga_obs=none tag=%s",
                wall_s, d.d_wall_s, static_cast<long long>(d.d_frames),
                static_cast<long long>(d.d_presents), static_cast<long long>(d.d_drops),
                static_cast<long long>(d.d_publish_misses),
                static_cast<long long>(d.d_residual),
                static_cast<long long>(d.d_pipe_bytes), gapTag,
                static_cast<long long>(frames), static_cast<long long>(presents),
                static_cast<long long>(drops), static_cast<long long>(publishMisses),
                static_cast<long long>(residual), fpsNum, fpsDen, src,
                sessionEpoch ? sessionEpoch : "NO-DATA", lineTag);
        }
    }
    return std::string(buf);
}

inline std::string formatSupplyTeardownLine(const SupplyPipeIdentity& id, size_t totalBytes,
                                            size_t frameBytes, int64_t ffmpegOut,
                                            const char* stageHint) {
    const std::string ff =
        ffmpegOut >= 0 ? std::to_string(ffmpegOut) : std::string("NO-DATA");
    char buf[512];
    std::snprintf(buf, sizeof(buf),
                  "supply_ledger total_bytes=%zu frame_bytes=%zu byte_aligned=%d "
                  "frames_from_bytes=%lld frame_index=%lld delta_frames_vs_bytes=%lld "
                  "ffmpeg_out_frames=%s identity_ok=%d stage_hint=%s tag=measured",
                  totalBytes, frameBytes, id.byte_aligned ? 1 : 0,
                  static_cast<long long>(id.frames_from_bytes),
                  static_cast<long long>(id.frame_index),
                  static_cast<long long>(id.delta_frames_vs_bytes), ff.c_str(), id.ok ? 1 : 0,
                  stageHint ? stageHint : "NO-DATA");
    return std::string(buf);
}

} // namespace misterplex
