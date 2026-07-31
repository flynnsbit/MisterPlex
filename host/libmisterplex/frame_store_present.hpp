// Hybrid / v0.2.0 product path: RTL frame_store + ddram_frame_rd are fixed
// 320×240 RGB565 (see fpga/.../frame_store.sv WIDTH/HEIGHT, ddram_frame_rd.sv).
//
// Historical defect (measured 2026-07-30, daemon 3e2cbb98): media_player gated
// FPGA present on `outW_ == 320 && outH_ == 240`, so DECODE=624x480 never called
// sendRgb*Frame, logged nothing, and pfps stayed 0.00 while decode ran at 23.6 vfps.
//
// Product policy (parent 2026-07-31):
//   - Never fail silently.
//   - Default: when PRESENT=fpga|both and decode does not fit the store, CLAMP decode
//     to 320×240 (same pixels as 240p, ~1× CPU) — do not pay 4× decode + scale tax.
//   - Opt-in PRESENT_SCALE_TO_STORE=1: keep oversized decode and scale at present
//     (debug / future larger store). Not marketed as "480p".

#pragma once

#include <cstdint>
#include <cstring>
#include <string>

namespace misterplex {

constexpr int kRgb565FrameStoreW = 320;
constexpr int kRgb565FrameStoreH = 240;
constexpr size_t kRgb565FrameStoreBytes =
    static_cast<size_t>(kRgb565FrameStoreW) * static_cast<size_t>(kRgb565FrameStoreH) * 2u;
constexpr size_t kRgb24FrameStoreBytes =
    static_cast<size_t>(kRgb565FrameStoreW) * static_cast<size_t>(kRgb565FrameStoreH) * 3u;

inline size_t rgb565FrameBytes(int w, int h) {
    if (w <= 0 || h <= 0)
        return 0;
    return static_cast<size_t>(w) * static_cast<size_t>(h) * 2u;
}

// Hybrid store holds a frame only when geometry matches the silicon constants.
inline bool frameStoreHoldsDecode(int decodeW, int decodeH) {
    return decodeW == kRgb565FrameStoreW && decodeH == kRgb565FrameStoreH;
}

// How to prepare a decoded RGB24 frame for the hybrid FPGA frame store.
enum class FpgaPresentPrep {
    Reject = 0,      // invalid, or oversized without scale opt-in — must log
    Identity = 1,    // already 320×240
    ScaleToStore = 2 // opt-in scale+letterbox into 320×240
};

// allowScaleToStore mirrors conf PRESENT_SCALE_TO_STORE (default false).
inline FpgaPresentPrep fpgaPresentPrep(int decodeW, int decodeH, bool allowScaleToStore) {
    if (decodeW <= 0 || decodeH <= 0)
        return FpgaPresentPrep::Reject;
    if (frameStoreHoldsDecode(decodeW, decodeH))
        return FpgaPresentPrep::Identity;
    if (allowScaleToStore)
        return FpgaPresentPrep::ScaleToStore;
    return FpgaPresentPrep::Reject;
}

// Legacy predicate that caused pfps=0 at DECODE=624x480 (do not use in product).
inline bool legacySilentSkipFpgaPresent(int decodeW, int decodeH) {
    return !frameStoreHoldsDecode(decodeW, decodeH);
}

// Resolve conf DECODE against the hybrid store before starting FFmpeg.
// presentFpga: PRESENT is fpga or both. allowScale: PRESENT_SCALE_TO_STORE.
struct DecodeStorePlan {
    int decode_w = 0;
    int decode_h = 0;
    bool clamped = false;
    bool will_scale_at_present = false;
    size_t requested_rgb565_bytes = 0;
    size_t store_rgb565_bytes = kRgb565FrameStoreBytes;
};

inline DecodeStorePlan planDecodeForHybridStore(int requestedW, int requestedH, bool presentFpga,
                                                bool allowScaleToStore) {
    DecodeStorePlan p{};
    p.decode_w = requestedW;
    p.decode_h = requestedH;
    p.requested_rgb565_bytes = rgb565FrameBytes(requestedW, requestedH);
    p.store_rgb565_bytes = kRgb565FrameStoreBytes;
    if (!presentFpga || requestedW <= 0 || requestedH <= 0)
        return p;
    if (frameStoreHoldsDecode(requestedW, requestedH))
        return p;
    if (allowScaleToStore) {
        p.will_scale_at_present = true;
        return p;
    }
    // Default: clamp decode to store — identical pixels to 240p, no 4× CPU tax.
    p.decode_w = kRgb565FrameStoreW;
    p.decode_h = kRgb565FrameStoreH;
    p.clamped = true;
    return p;
}

// One-shot log line for clamp (exact shape parent asked for).
inline std::string formatDecodeClampLog(int requestedW, int requestedH, const DecodeStorePlan& p) {
    return std::string("present: DECODE=") + std::to_string(requestedW) + "x" +
           std::to_string(requestedH) + " needs " +
           std::to_string(p.requested_rgb565_bytes) + " B but frame store is " +
           std::to_string(kRgb565FrameStoreW) + "x" + std::to_string(kRgb565FrameStoreH) +
           " RGB565 (" + std::to_string(p.store_rgb565_bytes) +
           " B) — clamping decode to " + std::to_string(p.decode_w) + "x" +
           std::to_string(p.decode_h);
}

// Banner / status field: always the EFFECTIVE geometry. When clamped, annotate
// the conf request so telemetry cannot lie (measured 2026-07-30: banner said
// decode=624x480 while player ran 320x240).
inline std::string formatDecodeGeometryLabel(int effectiveW, int effectiveH, int requestedW,
                                             int requestedH, bool clamped) {
    std::string s = std::to_string(effectiveW) + "x" + std::to_string(effectiveH);
    if (clamped && (requestedW != effectiveW || requestedH != effectiveH)) {
        s += " (clamped from " + std::to_string(requestedW) + "x" +
             std::to_string(requestedH) + ")";
    }
    return s;
}

// Letterbox/pillarbox nearest-neighbor scale of RGB24 into the 320×240 store.
// dst must hold kRgb24FrameStoreBytes. Opt-in path only (PRESENT_SCALE_TO_STORE=1).
inline bool scaleRgb24ToFrameStore(const uint8_t* src, int sw, int sh, uint8_t* dst) {
    if (!src || !dst || sw <= 0 || sh <= 0)
        return false;
    std::memset(dst, 0, kRgb24FrameStoreBytes); // black bars

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
