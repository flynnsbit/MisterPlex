#pragma once
// Behavioral model of post-ascal plex_chrome (host gate — not silicon).

#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/mister_video_mode.hpp"
#include "libmisterplex/plex_chrome_cmds.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace misterplex {
namespace plex_chrome_sim {

inline constexpr uint32_t kPlxcMagic = mailbox_abi::kPlxcMagic;
inline constexpr uint32_t kPlxoMagic = mailbox_abi::kPlxoMagic;
inline constexpr uint32_t kPlxcOffset = mailbox_abi::kPlxcOffset;
inline constexpr uint32_t kPlxoOffset = mailbox_abi::kPlxoOffset;

using plex_chrome_cmds::Op;
using plex_chrome_cmds::bodyScale;
using plex_chrome_cmds::kFontAdvance;
using plex_chrome_cmds::kFontH;
using plex_chrome_cmds::kFontW;
using plex_chrome_cmds::packGlyph;
using plex_chrome_cmds::packRect;

inline int fabricBodyScale(int hdmiH) { return bodyScale(hdmiH); }

// Minimal font matching RTL solid '#' and PAUSED letters
inline const uint8_t* font8x8(char ch) {
    static constexpr uint8_t sp[8] = {};
    static constexpr uint8_t P[8] = {0xFC, 0xC6, 0xC6, 0xFC, 0xC0, 0xC0, 0xC0, 0x00};
    static constexpr uint8_t A[8] = {0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0x00};
    static constexpr uint8_t U[8] = {0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00};
    static constexpr uint8_t S[8] = {0x7C, 0xC6, 0xC0, 0x7C, 0x06, 0xC6, 0x7C, 0x00};
    static constexpr uint8_t E[8] = {0xFE, 0xC0, 0xC0, 0xFC, 0xC0, 0xC0, 0xFE, 0x00};
    static constexpr uint8_t D[8] = {0xF8, 0xCC, 0xC6, 0xC6, 0xC6, 0xCC, 0xF8, 0x00};
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

struct Raster {
    int w = 0;
    int h = 0;
    std::vector<uint8_t> r, g, b;

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

    bool glyphInk(int x, int y) const {
        if (x < 0 || y < 0 || x >= w || y >= h)
            return false;
        const size_t i = static_cast<size_t>(y) * static_cast<size_t>(w) + static_cast<size_t>(x);
        return r[i] >= 200 && g[i] >= 200 && b[i] >= 200;
    }
};

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

inline void renderFabricWords(Raster& dst, int hdmiW, int hdmiH, const uint64_t* cmds, size_t ncmd) {
    dst.clear(hdmiW, hdmiH);
    const int scale = fabricBodyScale(hdmiH);
    for (size_t i = 0; i < ncmd; ++i) {
        const uint64_t w = cmds[i];
        const auto op = static_cast<Op>(w & 0xFF);
        if (op == Op::End)
            break;
        const int x = static_cast<int>((w >> 8) & 0xFFFF);
        const int y = static_cast<int>((w >> 24) & 0xFFFF);
        if (op == Op::Rect) {
            const int rw = static_cast<int>((w >> 40) & 0xFFF);
            const int rh = static_cast<int>((w >> 52) & 0xFFF);
            drawRect(dst, x, y, rw, rh, 0x14, 0x14, 0x28);
        } else if (op == Op::Glyph) {
            const char code = static_cast<char>((w >> 40) & 0xFF);
            drawGlyphNN(dst, x, y, code, scale, 255, 255, 255);
        } else if (op == Op::RectPal) {
            const int rw = static_cast<int>((w >> 40) & 0xFF);
            const int rh = static_cast<int>((w >> 48) & 0xFF);
            const int pal = static_cast<int>((w >> 56) & 0xFF);
            uint8_t rr = 0x14, gg = 0x14, bb = 0x28;
            if (pal == 2) {
                rr = 0xFF;
                gg = 0xB2;
                bb = 0x20;
            } else if (pal == 1) {
                rr = 0x3A;
                gg = 0x3F;
                bb = 0x48;
            }
            drawRect(dst, x, y, rw, rh, rr, gg, bb);
        }
    }
}

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
    for (int y = 0; y < hdmiH; ++y) {
        const int sy = (y * bankH) / hdmiH;
        for (int xx = 0; xx < hdmiW; ++xx) {
            const int sx = (xx * bankW) / hdmiW;
            if (bank.ink(sx, sy))
                dst.put(xx, y, 255, 255, 255);
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
    int cellH = 0;
    int cellW = 0;
};

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

// Fabric idle chevron model (matches idle_screen.hpp + RTL)
inline bool idleChevronHit(int x, int y, int ox, int oy, int size) {
    if (size <= 0)
        return false;
    const int lx = x - ox;
    const int ly = y - oy;
    if (lx < 0 || ly < 0 || lx >= size || ly >= size)
        return false;
    const int half = size / 2;
    const int stroke = size / 5 > 0 ? size / 5 : 1;
    const int d = ly <= half ? (lx - ly) : (lx - (size - 1 - ly));
    return d >= 0 && d < stroke;
}

inline void renderIdleFabric(Raster& dst, int w, int h, int mode /*0 logo 1 black*/) {
    dst.clear(w, h);
    if (mode == 1) {
        for (int y = 0; y < h; ++y)
            for (int x = 0; x < w; ++x)
                dst.put(x, y, 0, 0, 0);
        return;
    }
    int size = (w < h ? w : h) / 3;
    if (size < 4)
        size = 4;
    const int ox = (w - size) / 2;
    const int oy = (h - size) / 2;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            if (idleChevronHit(x, y, ox, oy, size))
                dst.put(x, y, 0xE5, 0xA0, 0x0D);
            else
                dst.put(x, y, 0x1F, 0x23, 0x26);
        }
    }
}

} // namespace plex_chrome_sim
} // namespace misterplex
