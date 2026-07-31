// Hybrid / v0.2.0 product path: RTL frame_store + ddram_frame_rd are fixed
// 320×240 RGB565 (see fpga/.../frame_store.sv WIDTH/HEIGHT, ddram_frame_rd.sv).
// DECODE conf may be larger (e.g. 624×480) for CPU ladder quality; ARM must still
// publish a 320×240 store frame or present is dead (pfps=0).
//
// Historical defect (measured 2026-07-30, daemon 3e2cbb98): media_player gated
// FPGA present on `outW_ == 320 && outH_ == 240`, so DECODE=624x480 never called
// sendRgb24FrameDdr / sendRgb24Frame, logged nothing, and pfps stayed 0.00 while
// decode ran at 23.6 vfps. Fix: always attempt present; scale into the store.

#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>

namespace misterplex {

constexpr int kRgb565FrameStoreW = 320;
constexpr int kRgb565FrameStoreH = 240;
constexpr size_t kRgb565FrameStoreBytes =
    static_cast<size_t>(kRgb565FrameStoreW) * static_cast<size_t>(kRgb565FrameStoreH) * 2u;
constexpr size_t kRgb24FrameStoreBytes =
    static_cast<size_t>(kRgb565FrameStoreW) * static_cast<size_t>(kRgb565FrameStoreH) * 3u;

// How to prepare a decoded RGB24 frame for the hybrid FPGA frame store.
enum class FpgaPresentPrep {
    Reject = 0,      // invalid geometry — must log
    Identity = 1,    // already 320×240
    ScaleToStore = 2 // scale+letterbox into 320×240 (never silent-skip)
};

// Production decision. Valid positive sizes always present (Identity or Scale).
// The legacy bug was equivalent to: (w==320 && h==240) ? Identity : Reject.
inline FpgaPresentPrep fpgaPresentPrep(int decodeW, int decodeH) {
    if (decodeW <= 0 || decodeH <= 0)
        return FpgaPresentPrep::Reject;
    if (decodeW == kRgb565FrameStoreW && decodeH == kRgb565FrameStoreH)
        return FpgaPresentPrep::Identity;
    return FpgaPresentPrep::ScaleToStore;
}

// Legacy predicate that caused pfps=0 at DECODE=624x480 (do not use in product).
inline bool legacySilentSkipFpgaPresent(int decodeW, int decodeH) {
    return !(decodeW == kRgb565FrameStoreW && decodeH == kRgb565FrameStoreH);
}

// Letterbox/pillarbox nearest-neighbor scale of RGB24 into the 320×240 store.
// dst must hold kRgb24FrameStoreBytes. Returns false on bad args.
inline bool scaleRgb24ToFrameStore(const uint8_t* src, int sw, int sh, uint8_t* dst) {
    if (!src || !dst || sw <= 0 || sh <= 0)
        return false;
    std::memset(dst, 0, kRgb24FrameStoreBytes); // black bars

    // Fit inside store preserving aspect ratio.
    const int64_t storeW = kRgb565FrameStoreW;
    const int64_t storeH = kRgb565FrameStoreH;
    int64_t dw = storeW;
    int64_t dh = (storeW * static_cast<int64_t>(sh)) / static_cast<int64_t>(sw);
    if (dh > storeH) {
        dh = storeH;
        dw = (storeH * static_cast<int64_t>(sw)) / static_cast<int64_t>(sh);
    }
    if (dw < 1)
        dw = 1;
    if (dh < 1)
        dh = 1;
    if (dw > storeW)
        dw = storeW;
    if (dh > storeH)
        dh = storeH;
    const int ox = static_cast<int>((storeW - dw) / 2);
    const int oy = static_cast<int>((storeH - dh) / 2);

    for (int y = 0; y < static_cast<int>(dh); ++y) {
        const int sy = static_cast<int>((static_cast<int64_t>(y) * sh) / dh);
        const int srcRow = sy * sw * 3;
        const int dstRow = (oy + y) * kRgb565FrameStoreW * 3;
        for (int x = 0; x < static_cast<int>(dw); ++x) {
            const int sx = static_cast<int>((static_cast<int64_t>(x) * sw) / dw);
            const int si = srcRow + sx * 3;
            const int di = dstRow + (ox + x) * 3;
            dst[di + 0] = src[si + 0];
            dst[di + 1] = src[si + 1];
            dst[di + 2] = src[si + 2];
        }
    }
    return true;
}

} // namespace misterplex
