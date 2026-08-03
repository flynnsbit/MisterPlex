#pragma once
// Content-bank overlay authoring size (SIZE A) — not HDMI glass (SIZE B).
//
// Parent FACT 2026-08-03: lab HDMI is already video_mode=0 = 1280x720@60 via
// ascal. 720p product work is CONTENT 1280x720 into the frame store so ascal
// does not upscale 640x480. Overlay chrome must track CONTENT/bank DE, else a
// successful FRAME_W=1280 fit still paints a 624 canvas stretched wrong.
//
// Priority (bank A only):
//   1) core/status applied DE when present (B20 freeze — w-mem/w-clock)
//   2) last PLXG couple H_DE/V_DE the daemon itself published
//   3) product floor plex480p (624x480) while FRAME_W/H stay 640/480 L4-off
//
// Glass B (mister_video_mode) is logged separately and must NOT drive bank
// authoring by itself — that would paint 1280 chrome into a 624 bank today.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/mister_video_mode.hpp"

#include <algorithm>
#include <cstdint>
#include <string>

namespace misterplex {

struct OverlayCanvas {
    int width = 0;
    int height = 0;
    // "applied" | "couple" | "floor480" | "explicit"
    const char* source = "floor480";
};

// True content bank candidates the host may author into (even rows/cols).
inline bool overlayCanvasDimsLegal(int w, int h) {
    if (w < 160 || h < 120)
        return false;
    if (w > 1920 || h > 1080)
        return false;
    if ((w & 1) || (h & 1))
        return false;
    return true;
}

// Resolve SIZE A. applied_* / couple_* are 0 when unknown.
inline OverlayCanvas resolveOverlayCanvas(int applied_w, int applied_h,
                                          int couple_w, int couple_h) {
    OverlayCanvas c;
    if (overlayCanvasDimsLegal(applied_w, applied_h)) {
        c.width = applied_w;
        c.height = applied_h;
        c.source = "applied";
        return c;
    }
    if (overlayCanvasDimsLegal(couple_w, couple_h)) {
        c.width = couple_w;
        c.height = couple_h;
        c.source = "couple";
        return c;
    }
    const DdrFrameGeometry g = plex480pDdrFrameGeometry();
    c.width = g.coded_width.get();
    c.height = g.coded_height.get();
    c.source = "floor480";
    return c;
}

// Explicit product content target when L4 FRAME_1280 enables (not glass).
inline OverlayCanvas resolveOverlayCanvasExplicit(int w, int h) {
    OverlayCanvas c;
    if (!overlayCanvasDimsLegal(w, h)) {
        return resolveOverlayCanvas(0, 0, 0, 0);
    }
    c.width = w;
    c.height = h;
    c.source = "explicit";
    return c;
}

// NEG: glass-only 1280x720 must NOT become bank canvas without couple/applied.
inline bool glassMustNotDriveBankCanvas(const MisterVideoMode& glass,
                                        const OverlayCanvas& bank) {
    if (!glass.ok)
        return true; // no glass claim — vacuously OK
    // If bank is still floor480 while glass is 720p, that is CORRECT today.
    if (glass.width == 1280 && glass.height == 720 && bank.source != nullptr &&
        std::string(bank.source) == "floor480" && bank.width == 624 &&
        bank.height == 480)
        return true;
    // Wrong implementation: bank copied glass without applied/couple.
    if (bank.source && std::string(bank.source) == "glass")
        return false;
    return true;
}

// Log fragment for idle overlay (matches osd shape; authoring = bank A).
inline std::string overlayCanvasLogTag(const OverlayCanvas& bank,
                                       const MisterVideoMode& glass) {
    std::string s = " canvas=" + std::to_string(bank.width) + "x" +
                    std::to_string(bank.height) + " authoring=" +
                    std::to_string(bank.width) + "x" + std::to_string(bank.height) +
                    " bank_src=" + (bank.source ? bank.source : "?");
    if (!glass.ok) {
        s += " output=DEFAULT_ASSUMED mode=? source=none";
    } else {
        s += " output=" + std::to_string(glass.width) + "x" +
             std::to_string(glass.height);
        if (glass.index >= 0)
            s += " mode=" + std::to_string(glass.index);
        else
            s += " mode=custom";
        s += " source=" + (glass.source.empty() ? std::string("ini") : glass.source);
    }
    return s;
}

// Body scale for content canvas (12x16 glyphs). Keep scale>=2 on even-row banks.
inline int overlayBodyScaleForCanvas(int canvas_h) {
    if (canvas_h <= 0)
        return 2;
    // Same half-to-even as computeOutputChromeLayout but floor at 2 for bank.
    const int q = canvas_h / 240;
    const int r = canvas_h % 240;
    int raw = q;
    if (r > 120)
        raw = q + 1;
    else if (r == 120)
        raw = (q % 2 == 0) ? q : (q + 1);
    if (raw < 2)
        raw = 2;
    if (raw > 8)
        raw = 8;
    return raw;
}

} // namespace misterplex
