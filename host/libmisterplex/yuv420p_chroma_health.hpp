// YUV420p chroma health for the DDR publish path (defect A / green-cast class).
//
// Silicon (RBF c5382bee + daemon e9f79de2): DECODE=624x480 with identity_skip
// produced a full green field with intact luma (U/V ~ 0, not neutral 128).
// DECODE=320x240 on the same core+daemon is colour-correct because that path
// always runs scale_pad_crop (arm_rescale=1) and regenerates I420 chroma.
//
// STREAM=0 has no per-plane copy — publish is a whole-frame memcpy of the
// rawvideo buffer. A zero-initialised frame vector whose chroma region was
// never populated therefore rings the doorbell with U=V=0 at the correct
// plane offsets (len still equals frame_bytes=449280).
//
// This header:
//   1) Detects the green-cast chroma fingerprint (near-zero U/V).
//   2) Repairs it to studio-neutral chroma (U=V=128) so scanout is greyscale
//      rather than green when the source region is dead.
//   3) Exposes the YUV-DDR scale policy: never SkipIdentity on that path.
#pragma once

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace misterplex {

struct Yuv420pChromaHealth {
    bool valid = false;       // geometry/len ok
    bool dead_chroma = false; // green-cast class (U/V near 0)
    double mean_u = 0.0;
    double mean_v = 0.0;
    double zero_frac_u = 0.0;
    double zero_frac_v = 0.0;
    size_t y_bytes = 0;
    size_t c_bytes = 0;
};

// Dead-chroma thresholds: nearly all samples ≤ max_abs and mean ≤ max_mean.
// Tuned to catch U=V=0 and pre-PLXD bank0 residue 0x04/0x19 without flagging
// real pure-green content (BT.601 G→ U≈43 V≈21 — V is low but U is not ≤32
// across the plane, so zero_frac_u stays near 0).
inline Yuv420pChromaHealth inspectYuv420pChroma(const uint8_t* yuv, int w, int h,
                                                uint8_t max_abs = 32,
                                                double max_mean = 32.0) {
    Yuv420pChromaHealth out;
    if (!yuv || w <= 0 || h <= 0 || (w & 1) || (h & 1))
        return out;
    out.y_bytes = static_cast<size_t>(w) * static_cast<size_t>(h);
    out.c_bytes = out.y_bytes / 4u;
    out.valid = true;
    const uint8_t* u = yuv + out.y_bytes;
    const uint8_t* v = yuv + out.y_bytes + out.c_bytes;
    uint64_t sumU = 0, sumV = 0, zU = 0, zV = 0;
    for (size_t i = 0; i < out.c_bytes; ++i) {
        const uint8_t uu = u[i];
        const uint8_t vv = v[i];
        sumU += uu;
        sumV += vv;
        if (uu <= max_abs)
            ++zU;
        if (vv <= max_abs)
            ++zV;
    }
    const double n = static_cast<double>(out.c_bytes);
    out.mean_u = static_cast<double>(sumU) / n;
    out.mean_v = static_cast<double>(sumV) / n;
    out.zero_frac_u = static_cast<double>(zU) / n;
    out.zero_frac_v = static_cast<double>(zV) / n;
    // Green-cast class: both planes dominated by near-zero samples and low mean.
    out.dead_chroma = (out.zero_frac_u >= 0.95 && out.zero_frac_v >= 0.95 &&
                       out.mean_u <= max_mean && out.mean_v <= max_mean);
    return out;
}

// If chroma is dead, fill U/V with studio black chroma (128). Returns true when
// a repair was applied. Y plane is never touched.
inline bool repairDeadYuv420pChroma(uint8_t* yuv, int w, int h) {
    const auto hth = inspectYuv420pChroma(yuv, w, h);
    if (!hth.valid || !hth.dead_chroma)
        return false;
    uint8_t* u = yuv + hth.y_bytes;
    uint8_t* v = yuv + hth.y_bytes + hth.c_bytes;
    std::memset(u, kYuv420BlackU, hth.c_bytes);
    std::memset(v, kYuv420BlackV, hth.c_bytes);
    return true;
}

// Product YUV DDR present path must not SkipIdentity: that is the 480p green-cast
// differential vs the colour-correct 240p scale_pad_crop path (parent silicon).
// Conf Off stays Off (lab). Always stays Always. SkipIdentity → Always.
inline FfmpegScaleMode ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode confMode) {
    if (confMode == FfmpegScaleMode::SkipIdentity)
        return FfmpegScaleMode::Always;
    return confMode;
}

} // namespace misterplex
