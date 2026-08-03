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

} // namespace misterplex
