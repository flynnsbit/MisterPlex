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
    double supply_gap = 0; // expected - d_frames
    bool ffmpeg_out_known = false;
};

// residual_arm = frames - presents - drops (supply-side; == publish_misses when closed).
inline int64_t supplyResidual(int64_t frames, int64_t presents, int64_t drops) {
    return frames - presents - drops;
}
// Uninstrumented gap (parent/user finding). Zero only if every non-present is
// either a pacer Drop or a counted publish miss.
inline int64_t supplyUnexplained(int64_t frames, int64_t presents, int64_t drops,
                                 int64_t publishMisses) {
    return frames - presents - drops - publishMisses;
}
// Deprecated alias — historical name meant residual_arm, NOT unexplained.
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
inline std::string formatSupplyBucketLine(const SupplyBucketDelta& d, double wall_s,
                                          int64_t frames, int64_t presents, int64_t drops,
                                          int64_t publishMisses, int64_t residual,
                                          int64_t ffmpegOut, int fpsNum, int fpsDen,
                                          const char* sessionEpoch) {
    char buf[1152];
    const int64_t residual_unexplained =
        supplyUnexplained(frames, presents, drops, publishMisses);
    const int64_t d_unexplained = d.d_residual - d.d_publish_misses;
    if (ffmpegOut >= 0) {
        std::snprintf(
            buf, sizeof(buf),
            "supply_bucket wall_s=%.3f d_wall_s=%.3f d_frames=%lld d_presents=%lld "
            "d_drops=%lld d_publish_misses=%lld d_residual=%lld "
            "d_residual_eq=frames-presents-drops d_residual_unexplained=%lld "
            "d_residual_unexplained_eq=d_residual-d_publish_misses "
            "residual_scope=supply_arm_only "
            "d_pipe_bytes=%lld expected_frames=%.3f supply_gap=%.3f d_ffmpeg_out=%lld "
            "ffmpeg_out_frames=%lld frames=%lld presents=%lld drops=%lld "
            "publish_misses=%lld residual=%lld residual_eq=frames-presents-drops "
            "residual_unexplained=%lld residual_unexplained_eq=frames-presents-drops-publish_misses "
            "iv_vfps=%.6f iv_pfps=%.6f "
            "fps=%d/%d fps_src=caller_supplied session_epoch=%s fpga_obs=none tag=measured",
            wall_s, d.d_wall_s, static_cast<long long>(d.d_frames),
            static_cast<long long>(d.d_presents), static_cast<long long>(d.d_drops),
            static_cast<long long>(d.d_publish_misses),
            static_cast<long long>(d.d_residual),
            static_cast<long long>(d_unexplained),
            static_cast<long long>(d.d_pipe_bytes), d.expected_frames, d.supply_gap,
            static_cast<long long>(d.d_ffmpeg_out), static_cast<long long>(ffmpegOut),
            static_cast<long long>(frames), static_cast<long long>(presents),
            static_cast<long long>(drops), static_cast<long long>(publishMisses),
            static_cast<long long>(residual),
            static_cast<long long>(residual_unexplained),
            d.d_wall_s > 0.0 ? (static_cast<double>(d.d_frames) / d.d_wall_s) : 0.0,
            d.d_wall_s > 0.0 ? (static_cast<double>(d.d_presents) / d.d_wall_s) : 0.0,
            fpsNum, fpsDen, sessionEpoch ? sessionEpoch : "NO-DATA");
    } else {
        std::snprintf(
            buf, sizeof(buf),
            "supply_bucket wall_s=%.3f d_wall_s=%.3f d_frames=%lld d_presents=%lld "
            "d_drops=%lld d_publish_misses=%lld d_residual=%lld "
            "d_residual_eq=frames-presents-drops d_residual_unexplained=%lld "
            "d_residual_unexplained_eq=d_residual-d_publish_misses "
            "residual_scope=supply_arm_only "
            "d_pipe_bytes=%lld expected_frames=%.3f supply_gap=%.3f d_ffmpeg_out=NO-DATA "
            "ffmpeg_out_frames=NO-DATA frames=%lld presents=%lld drops=%lld "
            "publish_misses=%lld residual=%lld residual_eq=frames-presents-drops "
            "residual_unexplained=%lld residual_unexplained_eq=frames-presents-drops-publish_misses "
            "iv_vfps=%.6f iv_pfps=%.6f "
            "fps=%d/%d fps_src=caller_supplied session_epoch=%s fpga_obs=none tag=measured",
            wall_s, d.d_wall_s, static_cast<long long>(d.d_frames),
            static_cast<long long>(d.d_presents), static_cast<long long>(d.d_drops),
            static_cast<long long>(d.d_publish_misses),
            static_cast<long long>(d.d_residual),
            static_cast<long long>(d_unexplained),
            static_cast<long long>(d.d_pipe_bytes), d.expected_frames, d.supply_gap,
            static_cast<long long>(frames), static_cast<long long>(presents),
            static_cast<long long>(drops), static_cast<long long>(publishMisses),
            static_cast<long long>(residual),
            static_cast<long long>(residual_unexplained),
            d.d_wall_s > 0.0 ? (static_cast<double>(d.d_frames) / d.d_wall_s) : 0.0,
            d.d_wall_s > 0.0 ? (static_cast<double>(d.d_presents) / d.d_wall_s) : 0.0,
            fpsNum, fpsDen, sessionEpoch ? sessionEpoch : "NO-DATA");
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
