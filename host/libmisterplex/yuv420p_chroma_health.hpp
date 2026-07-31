// YUV420p chroma health for the DDR publish path (defect A / green-cast class).
//
// Silicon (RBF c5382bee + daemon e9f79de2): DECODE=624x480 with identity_skip
// produced a full green field with intact luma (U/V ~ 0, not neutral 128).
// DECODE=320x240 on the same core+daemon is colour-correct (scale_pad_crop).
//
// RCA notes (source, parent-narrowed):
//   - clearYuv420pCropPadding is NOT the cause (border-only, U/V=128).
//   - frameBytes is coded 624x480 (449280), NOT display 618 or DECODE 320 —
//     under-read-from-display hypothesis is KILLED (media_player uses rawW/rawH
//     = ddrGeometry.coded_*).
//   - short-read always terminal (rawVideoTerminalSignal shortRead=true).
//   - std::vector frame(frameBytes) zero-inits → underfill shows as green.
//   - STREAM=0 publish is whole-frame memcpy; no per-plane 320-gate on tip.
//
// This header:
//   1) Detects the green-cast chroma fingerprint (near-zero U/V).
//   2) Fills a canvas with studio black (Y=16,U=V=128) instead of zeros.
//   3) Repairs dead chroma to U=V=128 (greyscale, not green).
//   4) YUV-DDR scale policy: never SkipIdentity on that path (match 240p).
#pragma once

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

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

// Studio black I420 canvas (not RGB-zero). Under-fill then reads as greyscale
// black rather than BT.601 green-cast.
inline bool fillYuv420pStudioBlack(uint8_t* yuv, int w, int h) {
    if (!yuv || w <= 0 || h <= 0 || (w & 1) || (h & 1))
        return false;
    const size_t yBytes = static_cast<size_t>(w) * static_cast<size_t>(h);
    const size_t cBytes = yBytes / 4u;
    std::memset(yuv, kYuv420BlackY, yBytes);
    std::memset(yuv + yBytes, kYuv420BlackU, cBytes);
    std::memset(yuv + yBytes + cBytes, kYuv420BlackV, cBytes);
    return true;
}

// Coded-bank frame byte count used by the STREAM=0 reader (NOT display WxH).
inline size_t yuv420pCodedFrameBytes(const DdrFrameGeometry& g) {
    return yuv420pFrameBytes(g.coded_width.get(), g.coded_height.get());
}

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

// YUV DDR present: force Always over SkipIdentity by DEFAULT.
// Silicon (parent viewed pixels): FORCE_SCALE=0 → magenta wrap + desync + defect B;
// FORCE_SCALE=1 → COLOR_OK + pfps 23.2. Escape hatch: conf DDR_YUV_FORCE_SCALE=0
// still hits the delivery_geometry_verified guard in buildFfmpegVideoFilter.
// Conf Off stays Off. Always stays Always. At 240p force is a no-op (320≠624).
inline FfmpegScaleMode ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode confMode,
                                                       bool forceScale = true) {
    if (forceScale && confMode == FfmpegScaleMode::SkipIdentity)
        return FfmpegScaleMode::Always;
    return confMode;
}

// PMS universal URL videoResolution is a REQUEST (upperBound only).
// library_media is PMS *scanner display metadata* — a claim, not a measurement
// (parent B4: hole on direct-play). Only a runtime-measured basis qualifies.
inline bool deliveryGeometryVerifiedFromBasis(const char* deliveryBasis) {
    if (!deliveryBasis)
        return false;
    return std::string(deliveryBasis) == "measured";
}

} // namespace misterplex
