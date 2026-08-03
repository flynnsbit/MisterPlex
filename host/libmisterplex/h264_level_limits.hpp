#pragma once
// H.264 (AVC) level limits used for DPB / ref-buffer sizing (w-mem).
//
// Parent 2026-08-03: product requests videoLevel=30 (Level 3.0) but PMS delivers
// 1280x720 at level=31 (Level 3.1) — 720p cannot be expressed at MaxFS of 3.0.
// Anything sizing a reference-frame buffer MUST key off the DELIVERED level_idc
// (SPS), not the REQUESTED plex_resolve h264Level.
//
// Near-term 720p path is still ARM decode + DMA→Option-C present banks.
// These limits bound endgame fabric DPB and any host-side ref staging.

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdint>

namespace misterplex {

// plex_resolve request defaults (quoted product code — do not "fix" these here).
constexpr int kPlexRequestedH264Level = 30; // videoLevel=30
constexpr const char* kPlexRequestedH264Profile = "baseline";

// Parent-measured delivery for real 1280x720 PMS stream.
constexpr int kPlexDeliveredH264Level720p = 31;    // level_times_10 form
constexpr uint8_t kPlexDeliveredLevelIdc720p = 31; // SPS level_idc byte

// ITU-T H.264 Annex A — subset we care about (macroblock units).
// MaxFS = max frame size (MBs). MaxDpbMbs = max decoded picture buffer (MB units).
struct H264LevelLimits {
    int level_times_10 = 0; // 30 = Level 3.0, 31 = Level 3.1
    uint32_t max_fs_mbs = 0;
    uint32_t max_dpb_mbs = 0;
};

// Table A-1 excerpts (progressive). Values from H.264 spec Annex A.
inline constexpr H264LevelLimits kH264Level3_0{30, 1620u, 8100u};
inline constexpr H264LevelLimits kH264Level3_1{31, 3600u, 18000u};
inline constexpr H264LevelLimits kH264Level3_2{32, 5120u, 20480u};
inline constexpr H264LevelLimits kH264Level4_0{40, 8192u, 32768u};

inline H264LevelLimits h264LevelLimits(int level_times_10) {
    switch (level_times_10) {
    case 30:
        return kH264Level3_0;
    case 31:
        return kH264Level3_1;
    case 32:
        return kH264Level3_2;
    case 40:
        return kH264Level4_0;
    default:
        return {}; // unknown — caller must not invent
    }
}

// Frame size in macroblocks (16x16), coded dimensions.
inline uint32_t h264FrameSizeMbs(int coded_w, int coded_h) {
    if (coded_w <= 0 || coded_h <= 0)
        return 0;
    const uint32_t mb_w = static_cast<uint32_t>((coded_w + 15) / 16);
    const uint32_t mb_h = static_cast<uint32_t>((coded_h + 15) / 16);
    return mb_w * mb_h;
}

// Max DPB frame slots = floor(MaxDpbMbs / FrameSizeInMbs). 0 if frame exceeds MaxFS.
inline uint32_t h264MaxDpbFrames(int level_times_10, int coded_w, int coded_h) {
    const auto lim = h264LevelLimits(level_times_10);
    if (lim.max_fs_mbs == 0)
        return 0;
    const uint32_t fs = h264FrameSizeMbs(coded_w, coded_h);
    if (fs == 0 || fs > lim.max_fs_mbs)
        return 0; // stream illegal at this level
    return lim.max_dpb_mbs / fs;
}

inline bool h264FrameFitsLevel(int level_times_10, int coded_w, int coded_h) {
    const auto lim = h264LevelLimits(level_times_10);
    const uint32_t fs = h264FrameSizeMbs(coded_w, coded_h);
    return fs > 0 && lim.max_fs_mbs > 0 && fs <= lim.max_fs_mbs;
}

// --- Product geometries (from layout constants) ---
// 1280x720 = 80*45 = 3600 MBs = exactly Level 3.1 MaxFS (not legal at 3.0).
constexpr uint32_t kPlex720pFrameSizeMbs = (1280u / 16u) * (720u / 16u); // 3600
// 624x480 coded product = 39*30 = 1170 MBs (fits Level 3.0).
constexpr uint32_t kPlex480pCodedFrameSizeMbs = ((624u + 15u) / 16u) * (480u / 16u); // 1170

// DPB frame slots if sized from REQUEST (wrong) vs DELIVERED (correct) at 720p.
constexpr uint32_t kDpbFrames720pIfSizedFromRequestL30 = 0; // 3600 > 1620 MaxFS
constexpr uint32_t kDpbFrames720pFromDeliveredL31 = 18000u / 3600u; // 5

// Bytes for one I420 ref frame at 720p (same as present bank payload).
constexpr uint32_t kDpb720pFrameBytes = static_cast<uint32_t>(kPlex720pYuv420pBytes);
// Full DPB storage if fabric held max L3.1 refs (endgame bound — not near-term alloc).
constexpr uint32_t kDpb720pMaxBytesL31 = kDpbFrames720pFromDeliveredL31 * kDpb720pFrameBytes;
// 5 * 1382400 = 6912000

// Present path Option-C is DOUBLE-BUFFER display banks (2), NOT the H.264 DPB.
// Do not conflate kPlex720p map banks with DPB frame count.
constexpr uint32_t kOptionCPresentBankCount = 2u;

static_assert(kPlex720pFrameSizeMbs == 3600u, "720p MB count");
static_assert(kPlex480pCodedFrameSizeMbs == 1170u, "480p coded MB count");
static_assert(kDpbFrames720pFromDeliveredL31 == 5u, "L3.1 DPB frames @720p");
static_assert(kPlex720pFrameSizeMbs > kH264Level3_0.max_fs_mbs,
              "720p exceeds Level 3.0 MaxFS — delivered level must be >= 31");
static_assert(kPlex720pFrameSizeMbs == kH264Level3_1.max_fs_mbs,
              "720p sits exactly on Level 3.1 MaxFS");

} // namespace misterplex
