#pragma once
// PMS universal delivery geometry — host-side math only (no network).
//
// Product fact (measured on lab PMS, RK6, 2026-08-02):
//   videoResolution=WxH is a CEILING for aspect-preserving square-pixel fit,
//   not an exact coded size. Anamorphic sources (non-1:1 SAR) whose *display*
//   aspect is 16:9 fit to ~624x350 inside a 624x480 bound.
//
// See .agent-work/w-geom/PMS_350_TRUE_480_RCA.md for the decision matrix.

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <string>

namespace misterplex {

struct RationalAspect {
    int num = 0;
    int den = 0;
    bool valid() const { return num > 0 && den > 0; }
    double asDouble() const {
        if (!valid())
            return 0.0;
        return static_cast<double>(num) / static_cast<double>(den);
    }
};

// Parse "160:117" or "1.78" style ratios. Colon form preferred (exact).
inline bool parseAspectRatioToken(const std::string& s, RationalAspect& out) {
    out = {};
    if (s.empty())
        return false;
    const auto colon = s.find(':');
    if (colon != std::string::npos) {
        const int n = std::atoi(s.c_str());
        const int d = std::atoi(s.c_str() + colon + 1);
        if (n <= 0 || d <= 0)
            return false;
        out.num = n;
        out.den = d;
        return true;
    }
    // Decimal (Media@aspectRatio="1.78") — approximate as n/100 when possible.
    char* end = nullptr;
    const double v = std::strtod(s.c_str(), &end);
    if (end == s.c_str() || v <= 0.0)
        return false;
    // Keep hundredths; 1.78 → 178/100.
    out.num = static_cast<int>(std::lround(v * 100.0));
    out.den = 100;
    if (out.num <= 0)
        return false;
    return true;
}

// Display aspect = (coded_w/coded_h) * (sar_n/sar_d). SAR 1:1 → storage aspect.
inline double displayAspectFromCodedAndSar(int coded_w, int coded_h, int sar_n, int sar_d) {
    if (coded_w <= 0 || coded_h <= 0 || sar_n <= 0 || sar_d <= 0)
        return 0.0;
    return (static_cast<double>(coded_w) / static_cast<double>(coded_h)) *
           (static_cast<double>(sar_n) / static_cast<double>(sar_d));
}

// Prefer Stream@pixelAspectRatio; else Media@aspectRatio as DAR directly.
inline double resolveContentDar(int coded_w, int coded_h, const std::string& pixelAspectRatio,
                                const std::string& mediaAspectRatio) {
    RationalAspect sar;
    if (parseAspectRatioToken(pixelAspectRatio, sar) && sar.valid()) {
        const double dar = displayAspectFromCodedAndSar(coded_w, coded_h, sar.num, sar.den);
        if (dar > 0.0)
            return dar;
    }
    RationalAspect mar;
    if (parseAspectRatioToken(mediaAspectRatio, mar) && mar.valid())
        return mar.asDouble();
    if (coded_w > 0 && coded_h > 0)
        return static_cast<double>(coded_w) / static_cast<double>(coded_h);
    return 0.0;
}

struct SquarePixelFit {
    int w = 0;
    int h = 0;
    bool ok = false;
};

// Even-floor (PMS/x264 style) after aspect-fit into max_w x max_h ceiling.
// Matches lab decision: 16:9 into 624x480 → 624x350 (351 even-floored).
inline SquarePixelFit pmsSquarePixelFitInCeiling(double dar, int max_w, int max_h) {
    SquarePixelFit out;
    if (!(dar > 0.0) || max_w <= 0 || max_h <= 0)
        return out;
    // Width-limited candidate.
    double h_from_w = static_cast<double>(max_w) / dar;
    // Height-limited candidate.
    double w_from_h = static_cast<double>(max_h) * dar;
    int w = 0, h = 0;
    if (h_from_w <= static_cast<double>(max_h) + 1e-9) {
        w = max_w;
        h = static_cast<int>(std::floor(h_from_w));
    } else {
        h = max_h;
        w = static_cast<int>(std::floor(w_from_h));
    }
    // Even floor (chroma / macroblock-friendly).
    if (w & 1)
        --w;
    if (h & 1)
        --h;
    if (w <= 0 || h <= 0)
        return out;
    out.w = w;
    out.h = h;
    out.ok = true;
    return out;
}

// True 480 rows of *square-pixel* 16:9 need width ≈ 480*(16/9) = 853.33.
// That exceeds the synthesis-fixed DDR coded width 624 — impossible in-bank.
inline int squarePixelWidthForHeight(double dar, int height) {
    if (!(dar > 0.0) || height <= 0)
        return 0;
    int w = static_cast<int>(std::lround(static_cast<double>(height) * dar));
    if (w & 1)
        ++w; // even up for chroma
    return w;
}

// Fraction of requested vertical samples retained after square-pixel fit.
inline double verticalDetailFraction(int delivered_h, int requested_h) {
    if (delivered_h <= 0 || requested_h <= 0)
        return 0.0;
    return static_cast<double>(delivered_h) / static_cast<double>(requested_h);
}

// pipeDesyncRisk requires identity_skip — scale_mode=always sessions cannot
// use producer/reader byte ratios as a desync model (parent correction).
inline bool desyncModelApplicable(bool identity_skip) { return identity_skip; }

// Genuine tier delivery: PMS videoResolution is a CEILING. A 720p *request* that
// lands as 720x404 (bitrate-starved) or 624x350 (16:9 fit into 480 ceiling) is
// NOT true 720p — ARM must not identity_skip or claim path-720 success.
// Exact WxH match only (no "close enough" / no SAR compensation here).
inline bool isGenuineTierDelivery(int delivered_w, int delivered_h, int tier_w, int tier_h) {
    if (delivered_w <= 0 || delivered_h <= 0 || tier_w <= 0 || tier_h <= 0)
        return false;
    return delivered_w == tier_w && delivered_h == tier_h;
}

inline bool isGenuine720pDelivery(int delivered_w, int delivered_h) {
    return isGenuineTierDelivery(delivered_w, delivered_h, 1280, 720);
}

// Exact 960x540 **display/ffmpeg** size — shippable fabric→720 glass source
// (not true 720 source). Match against decoder output after H.264 frame_crop
// (SPS MB may be 960x544; ARM never publishes the uncropped MB buffer).
// Negatives: 720x404 (maxBR starvation), 720x540 (4:3 fit), 960x536, 854x480.
inline bool isGenuine540pDelivery(int delivered_w, int delivered_h) {
    return isGenuineTierDelivery(delivered_w, delivered_h, 960, 540);
}

// Exact 640x360 display after libav crop (SPS MB 368 / crop 8). Exact 2× glass.
// Negatives: 480x270 (maxBR=750), 320x180 (maxBR=400), 640x368 MB height.
inline bool isGenuine360pDelivery(int delivered_w, int delivered_h) {
    return isGenuineTierDelivery(delivered_w, delivered_h, 640, 360);
}

// Lab-measured maxVideoBitrate knee for genuine 960x540 on 16:9 HD sources
// (daemon path + unique session, local PMS 2026-08-03):
//   rk2/rk7: maxBR=1500 → 720x404; maxBR≥2000 → 960x540 SAR 1:1.
// Product weak = kPlex540pWeakBitrateKbps (2000) sits on the measured knee.
inline constexpr int kPmsTrue540pMinBitrateKbpsMeasured = 2000;

inline bool pmsBitrateLikelyTrue540p(int maxVideoBitrateKbps) {
    return maxVideoBitrateKbps >= kPmsTrue540pMinBitrateKbpsMeasured;
}

// Lab knee for genuine 640x360 (rk2/rk142, ceiling 640x360, 2026-08-03):
//   maxBR=400 → 320x180; 750 → 480x270; ≥1000 → 640x360 SAR 1:1.
inline constexpr int kPmsTrue360pMinBitrateKbpsMeasured = 1000;

inline bool pmsBitrateLikelyTrue360p(int maxVideoBitrateKbps) {
    return maxVideoBitrateKbps >= kPmsTrue360pMinBitrateKbpsMeasured;
}

// Lab-measured maxVideoBitrate gate for true 1280x720 on 16:9 HD sources
// (daemon URL builder + unique session, lab PMS 2026-08-03 fine matrix):
//   rk2: maxBR=3000 → 720x404; maxBR=3100 → 1280x720 SAR 1:1 (start.mp4 ffprobe).
//   Decision content bitrate @ maxBR=3100 ≈ 2585 kbps (cap under-run).
//   maxBR=1500/2000/2500/3000 → 720x404 — cannot force full height below the step.
//   rk7 @2500 → 720x404; decision @3200+ → 1280x720.
//   rk83 4:3 @4000 → coded **960x720** (square-pixel fit — not full width).
// Parent device decode of *already* 1280x720@1500k is a content/DP tier, not this gate.
// Product universal weak = kPlex720pWeakBitrateKbps (3100 geometry floor).
inline constexpr int kPmsTrue720pMinBitrateKbpsMeasured = 3100;

inline bool pmsBitrateLikelyTrue720p(int maxVideoBitrateKbps) {
    return maxVideoBitrateKbps >= kPmsTrue720pMinBitrateKbpsMeasured;
}

// Play-time delivery basis string for GEOM / identity_skip.
// Direct Play Part: file samples = delivery (verified). Universal/transcode:
// request or library claim only (unverified until measured).
inline const char* deliveryBasisForResolve(bool ok, bool transcoded, int media_w,
                                           int media_h, bool has_transcode_request_wh) {
    if (!ok)
        return "unknown";
    if (transcoded)
        return has_transcode_request_wh ? "transcode_request" : "unknown";
    if (media_w > 0 && media_h > 0)
        return "direct_play_part";
    return "unknown";
}

} // namespace misterplex
