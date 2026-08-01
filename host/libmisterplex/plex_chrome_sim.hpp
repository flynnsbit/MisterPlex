#pragma once
// Behavioral model of post-ascal plex_chrome (design / host gate — not silicon).
//
// Mirrors docs/plex-chrome-plane-rtl-proposal.md:
//   - Geometry authority: HDMI_WIDTH / HDMI_HEIGHT (fabric wires), not ARM.
//   - bodyScale = clamp(2..8, half-even round(H/240)) — same as computeOutputChromeLayout.
//   - Glyphs: integer nearest-neighbour expand by bodyScale (osd.v pattern).
//   - ARM supplies semantic list only (RECT / GLYPH / END); no pixels.
//
// Used by tests/unit/test_plex_chrome_sim.cpp to prove:
//   GREEN — integer fabric path keeps glyph edges sharp at ≥2 output geometries
//   RED   — bank-bake-then-stretch (product today) fails the same edge metric

#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/mister_video_mode.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace misterplex {
namespace plex_chrome_sim {

// Re-export ABI (single source: mailbox_abi_spec.hpp).
inline constexpr uint32_t kPlxcMagic = mailbox_abi::kPlxcMagic;
inline constexpr uint32_t kPlxoMagic = mailbox_abi::kPlxoMagic;
inline constexpr uint32_t kPlxcOffset = mailbox_abi::kPlxcOffset;
inline constexpr uint32_t kPlxoOffset = mailbox_abi::kPlxoOffset;

enum class Op : uint8_t { End = 0, Rect = 1, Glyph = 2 };

// 64-bit command word (little-endian layout, host model).
struct Cmd {
    Op op = Op::End;
    uint16_t x = 0;
    uint16_t y = 0;
    uint16_t w = 0;     // RECT width / unused for GLYPH
    uint16_t h = 0;     // RECT height
    uint8_t code = 0;   // GLYPH: ASCII
    uint8_t rgba_r = 255;
    uint8_t rgba_g = 255;
    uint8_t rgba_b = 255;
};

// Minimal 8×8 1bpp font (MSB left). Enough for "PAUSED" edge tests.
// Row-major 8 rows; bit7 = leftmost pixel.
inline const uint8_t* font8x8(char ch) {
    static constexpr uint8_t sp[8] = {};
    static constexpr uint8_t P[8] = {0xFC, 0xC6, 0xC6, 0xFC, 0xC0, 0xC0, 0xC0, 0x00};
    static constexpr uint8_t A[8] = {0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0x00};
    static constexpr uint8_t U[8] = {0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00};
    static constexpr uint8_t S[8] = {0x7C, 0xC6, 0xC0, 0x7C, 0x06, 0xC6, 0x7C, 0x00};
    static constexpr uint8_t E[8] = {0xFE, 0xC0, 0xC0, 0xFC, 0xC0, 0xC0, 0xFE, 0x00};
    static constexpr uint8_t D[8] = {0xF8, 0xCC, 0xC6, 0xC6, 0xC6, 0xCC, 0xF8, 0x00};
    // Solid 8×8 block for edge-metric gates (no blank baseline row).
    static constexpr uint8_t blk[8] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    if (ch >= 'a' && ch <= 'z')
        ch = static_cast<char>(ch - 'a' + 'A');
    switch (ch) {
    case 'P': return P;
    case 'A': return A;
    case 'U': return U;
    case 'S': return S;
    case 'E': return E;
    case 'D': return D;
    case '#': return blk;
    default: return sp;
    }
}

inline constexpr int kFontW = 8;
inline constexpr int kFontH = 8;
inline constexpr int kFontAdvance = 9;

inline int fabricBodyScale(int hdmiH) {
    // Must match mister_video_mode.hpp computeOutputChromeLayout half-even rule.
    if (hdmiH <= 0)
        return 2;
    const int q = hdmiH / 240;
    const int r = hdmiH % 240;
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

struct Raster {
    int w = 0;
    int h = 0;
    std::vector<uint8_t> r, g, b; // 8-bit planes; 0 = transparent / bg

    void clear(int ww, int hh) {
        w = ww;
        h = hh;
        const size_t n = static_cast<size_t>(ww) * static_cast<size_t>(hh);
        r.assign(n, 0);
        g.assign(n, 0);
        b.assign(n, 0);
    }

    void put(int x, int y, uint8_t rr, uint8_t gg, uint8_t bb) {
        if (x < 0 || y < 0 || x >= w || y >= h)
            return;
        const size_t i = static_cast<size_t>(y) * static_cast<size_t>(w) + static_cast<size_t>(x);
        r[i] = rr;
        g[i] = gg;
        b[i] = bb;
    }

    bool ink(int x, int y) const {
        if (x < 0 || y < 0 || x >= w || y >= h)
            return false;
        const size_t i = static_cast<size_t>(y) * static_cast<size_t>(w) + static_cast<size_t>(x);
        return r[i] | g[i] | b[i];
    }

    // Glyph ink only (near-white) — excludes dark panel RECT fills from edge metrics.
    bool glyphInk(int x, int y) const {
        if (x < 0 || y < 0 || x >= w || y >= h)
            return false;
        const size_t i = static_cast<size_t>(y) * static_cast<size_t>(w) + static_cast<size_t>(x);
        return r[i] >= 200 && g[i] >= 200 && b[i] >= 200;
    }
};

// Integer NN fill of one font bit cell (fabric hot path).
inline void fillCellNN(Raster& dst, int x0, int y0, int scale, uint8_t rr, uint8_t gg, uint8_t bb) {
    for (int dy = 0; dy < scale; ++dy)
        for (int dx = 0; dx < scale; ++dx)
            dst.put(x0 + dx, y0 + dy, rr, gg, bb);
}

inline void drawGlyphNN(Raster& dst, int x, int y, char ch, int scale, uint8_t rr, uint8_t gg,
                        uint8_t bb) {
    const uint8_t* rows = font8x8(ch);
    for (int row = 0; row < kFontH; ++row) {
        const uint8_t bits = rows[row];
        for (int col = 0; col < kFontW; ++col) {
            if (bits & static_cast<uint8_t>(0x80u >> col))
                fillCellNN(dst, x + col * scale, y + row * scale, scale, rr, gg, bb);
        }
    }
}

inline void drawRect(Raster& dst, int x, int y, int ww, int hh, uint8_t rr, uint8_t gg, uint8_t bb) {
    for (int yy = y; yy < y + hh; ++yy)
        for (int xx = x; xx < x + ww; ++xx)
            dst.put(xx, yy, rr, gg, bb);
}

// Fabric path: scale from HDMI_HEIGHT; cmds carry LOGICAL (unscaled font cell) coords
// in units of font cells for glyphs — here we use output-pixel origins already decided
// by a layout helper that used the same bodyScale (ARM preview may match; fabric owns scale).
inline void renderFabric(Raster& dst, int hdmiW, int hdmiH, const Cmd* cmds, size_t ncmd) {
    dst.clear(hdmiW, hdmiH);
    const int scale = fabricBodyScale(hdmiH);
    for (size_t i = 0; i < ncmd; ++i) {
        const Cmd& c = cmds[i];
        if (c.op == Op::End)
            break;
        if (c.op == Op::Rect) {
            drawRect(dst, c.x, c.y, c.w, c.h, c.rgba_r, c.rgba_g, c.rgba_b);
        } else if (c.op == Op::Glyph) {
            // x,y are OUTPUT pixel origins (ARM may compute with same formula).
            // Fabric ALWAYS expands by fabricBodyScale(hdmiH) — never ARM-supplied scale.
            drawGlyphNN(dst, c.x, c.y, static_cast<char>(c.code), scale, c.rgba_r, c.rgba_g,
                        c.rgba_b);
        }
    }
}

// Product bug model: author glyphs at bankW×bankH with bankScale, then NN-stretch
// to hdmiW×hdmiH (present_core + ascal). This is what glass shows as "blocky".
inline void renderBankThenStretch(Raster& dst, int bankW, int bankH, int bankScale, int hdmiW,
                                  int hdmiH, const char* text, int textXBank, int textYBank) {
    Raster bank;
    bank.clear(bankW, bankH);
    int x = textXBank;
    for (const char* p = text; p && *p; ++p) {
        drawGlyphNN(bank, x, textYBank, *p, bankScale, 255, 255, 255);
        x += kFontAdvance * bankScale;
    }
    dst.clear(hdmiW, hdmiH);
    // Integer-nearest map (ascal-like sample). Fractional mapping → irregular edge runs.
    for (int y = 0; y < hdmiH; ++y) {
        const int sy = (y * bankH) / hdmiH; // trunc — irregular when ratios not integer
        for (int x = 0; x < hdmiW; ++x) {
            const int sx = (x * bankW) / hdmiW;
            if (bank.ink(sx, sy))
                dst.put(x, y, 255, 255, 255);
        }
    }
}

struct EdgeStats {
    int inkPixels = 0;
    int hRuns = 0;
    int hRunsNotMultipleOfScale = 0;
    int vRuns = 0;
    int vRunsNotMultipleOfScale = 0;
    int minHRun = 0;
    int maxHRun = 0;
    int cellH = 0; // measured ink bbox height
    int cellW = 0;
};

// Edge sharpness: every maximal horizontal/vertical ink run length must be a
// multiple of `scale` (integer NN cells). Fractional bank-stretch fails this
// when HDMI/bank is not an integer ratio (1080/480 = 2.25).
inline EdgeStats measureEdgeRuns(const Raster& r, int scale) {
    EdgeStats s;
    if (scale < 1)
        scale = 1;
    int minx = r.w, miny = r.h, maxx = -1, maxy = -1;
    for (int y = 0; y < r.h; ++y) {
        int run = 0;
        for (int x = 0; x < r.w; ++x) {
            if (r.glyphInk(x, y)) {
                ++s.inkPixels;
                ++run;
                minx = std::min(minx, x);
                maxx = std::max(maxx, x);
                miny = std::min(miny, y);
                maxy = std::max(maxy, y);
            } else if (run > 0) {
                ++s.hRuns;
                if (s.minHRun == 0 || run < s.minHRun)
                    s.minHRun = run;
                if (run > s.maxHRun)
                    s.maxHRun = run;
                if ((run % scale) != 0)
                    ++s.hRunsNotMultipleOfScale;
                run = 0;
            }
        }
        if (run > 0) {
            ++s.hRuns;
            if (s.minHRun == 0 || run < s.minHRun)
                s.minHRun = run;
            if (run > s.maxHRun)
                s.maxHRun = run;
            if ((run % scale) != 0)
                ++s.hRunsNotMultipleOfScale;
        }
    }
    for (int x = 0; x < r.w; ++x) {
        int run = 0;
        for (int y = 0; y < r.h; ++y) {
            if (r.glyphInk(x, y)) {
                ++run;
            } else if (run > 0) {
                ++s.vRuns;
                if ((run % scale) != 0)
                    ++s.vRunsNotMultipleOfScale;
                run = 0;
            }
        }
        if (run > 0) {
            ++s.vRuns;
            if ((run % scale) != 0)
                ++s.vRunsNotMultipleOfScale;
        }
    }
    if (maxx >= minx && maxy >= miny) {
        s.cellW = maxx - minx + 1;
        s.cellH = maxy - miny + 1;
    }
    return s;
}

// Build a PAUSED glyph list at output coords using fabric scale (semantic ARM preview).
inline std::vector<Cmd> makePausedList(int hdmiW, int hdmiH) {
    const int scale = fabricBodyScale(hdmiH);
    const int textH = kFontH * scale;
    const int adv = kFontAdvance * scale;
    const char* t = "PAUSED";
    const int n = 6;
    const int totalW = n * adv - scale;
    const int x0 = std::max(0, (hdmiW - totalW) / 2);
    const int y0 = std::max(0, hdmiH - textH - std::max(8, hdmiH / 16));
    std::vector<Cmd> cmds;
    cmds.reserve(static_cast<size_t>(n) + 2u);
    Cmd panel;
    panel.op = Op::Rect;
    panel.x = static_cast<uint16_t>(std::max(0, x0 - 8));
    panel.y = static_cast<uint16_t>(std::max(0, y0 - 4));
    panel.w = static_cast<uint16_t>(std::min(hdmiW - panel.x, totalW + 16));
    panel.h = static_cast<uint16_t>(std::min(hdmiH - panel.y, textH + 8));
    panel.rgba_r = 20;
    panel.rgba_g = 20;
    panel.rgba_b = 40;
    cmds.push_back(panel);
    int x = x0;
    for (int i = 0; i < n; ++i) {
        Cmd g;
        g.op = Op::Glyph;
        g.x = static_cast<uint16_t>(x);
        g.y = static_cast<uint16_t>(y0);
        g.code = static_cast<uint8_t>(t[i]);
        g.rgba_r = g.rgba_g = g.rgba_b = 255;
        cmds.push_back(g);
        x += adv;
    }
    Cmd end;
    end.op = Op::End;
    cmds.push_back(end);
    return cmds;
}

} // namespace plex_chrome_sim
} // namespace misterplex
