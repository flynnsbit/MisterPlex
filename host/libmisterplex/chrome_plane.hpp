#pragma once
// ARM half of the post-ascal chrome plane (w-osd-hires).
//
// plane=0 (product today): PlaybackOverlay bakes into F1 coded bank → present_core
// decimates. Glass proof (parent push_frame even/odd): only even store rows reach
// display — ARM-only F1 sharpness is cosmetic.
//
// plane=1 (with w-fit RBF): paint at HDMI W×H via this API, doorbell chrome band;
// do NOT call renderOverlay(cleanFrame). Fail closed without HW bit.
//
// See docs/osd-native-raster-arm-design.md, docs/chrome-post-scale-plane-design.md.

#include "libmisterplex/mister_video_mode.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace misterplex {

// Transparent key for RGB565 plane blend (w-fit ABI placeholder).
inline constexpr uint16_t kChromePlaneColorKey = 0x0001;

struct ChromePlanePaintResult {
    int outW = 0;
    int outH = 0;
    int bodyScale = 0;
    int advancePx = 0;
    bool useLargeFont = false;
    OverlayRect dirty{};
    OverlayRect panel{};
    size_t bytes = 0;
    bool ok = false;
};

// RAII: force PlaybackOverlay metrics from computeOutputChromeLayout.
class OutputRasterLayoutGuard {
public:
    explicit OutputRasterLayoutGuard(PlaybackOverlay& ov, bool enable = true)
        : ov_(ov), prev_(ov.outputRasterLayout()) {
        ov_.setOutputRasterLayout(enable);
    }
    ~OutputRasterLayoutGuard() { ov_.setOutputRasterLayout(prev_); }
    OutputRasterLayoutGuard(const OutputRasterLayoutGuard&) = delete;
    OutputRasterLayoutGuard& operator=(const OutputRasterLayoutGuard&) = delete;

private:
    PlaybackOverlay& ov_;
    bool prev_;
};

// Fill RGB565LE buffer (outW*outH*2 bytes) with color key, then composite chrome
// at OUTPUT raster metrics. Event-driven only — never from presentCleanFrame @60Hz.
inline bool paintChromePlaneRgb565(PlaybackOverlay& ov, uint8_t* rgb565le, int outW, int outH,
                                   ChromePlanePaintResult* meta = nullptr) {
    ChromePlanePaintResult local;
    ChromePlanePaintResult& r = meta ? *meta : local;
    r = ChromePlanePaintResult{};
    r.outW = outW;
    r.outH = outH;
    if (!rgb565le || outW <= 0 || outH <= 0)
        return false;

    const OutputChromeLayout L = computeOutputChromeLayout(outW, outH);
    r.bodyScale = L.bodyScale;
    r.advancePx = L.advancePx;
    r.useLargeFont = L.useLargeFont;
    r.bytes = static_cast<size_t>(outW) * static_cast<size_t>(outH) * 2u;

    auto* px = reinterpret_cast<uint16_t*>(rgb565le);
    const size_t n = static_cast<size_t>(outW) * static_cast<size_t>(outH);
    for (size_t i = 0; i < n; ++i)
        px[i] = kChromePlaneColorKey;

    OutputRasterLayoutGuard guard(ov, true);
    r.panel = PlaybackOverlay::panelBounds(outW, outH, true);
    r.dirty = ov.dirtyBounds(outW, outH);
    if (r.dirty.empty()) {
        r.ok = false;
        return false;
    }
    r.ok = ov.renderRgb565Le(rgb565le, outW, outH);
    return r.ok;
}

// Bottom HUD band only (cost path). y in [bandY0, outH). Stride = outW*2.
inline bool paintChromePlaneBandRgb565(PlaybackOverlay& ov, std::vector<uint8_t>& band, int outW,
                                       int outH, int* bandY0Out = nullptr,
                                       ChromePlanePaintResult* meta = nullptr) {
    ChromePlanePaintResult fullMeta;
    std::vector<uint8_t> full(static_cast<size_t>(outW) * static_cast<size_t>(outH) * 2u);
    if (!paintChromePlaneRgb565(ov, full.data(), outW, outH, &fullMeta) || !fullMeta.ok) {
        if (meta)
            *meta = fullMeta;
        return false;
    }
    const int y0 = fullMeta.dirty.y;
    const int y1 = fullMeta.dirty.y + fullMeta.dirty.h;
    if (y0 < 0 || y1 > outH || y1 <= y0)
        return false;
    const int bh = y1 - y0;
    band.resize(static_cast<size_t>(outW) * static_cast<size_t>(bh) * 2u);
    for (int row = 0; row < bh; ++row) {
        std::memcpy(band.data() + static_cast<size_t>(row) * outW * 2u,
                    full.data() + static_cast<size_t>(y0 + row) * outW * 2u,
                    static_cast<size_t>(outW) * 2u);
    }
    if (bandY0Out)
        *bandY0Out = y0;
    if (meta) {
        *meta = fullMeta;
        meta->bytes = band.size();
    }
    return true;
}

// Fail-closed live gate: conf alone must NOT blank chrome on old RBF.
// Live requires HW feature bit (status/mailbox) once w-fit publishes it.
inline bool chromePlaneLiveAllowed(bool confWantsPlane, bool hwPlanePresent) {
    return confWantsPlane && hwPlanePresent;
}

} // namespace misterplex
