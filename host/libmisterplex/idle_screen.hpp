#pragma once
// Idle / screensaver frame renderer for the Plex core.
//
// Why this exists: the FPGA frame store (F1) and /dev/fb0 both latch the LAST
// frame written. When a session ends nothing overwrites them, so the final frame
// of the last video stays on screen indefinitely — on a CRT that is a burn-in
// risk, and it looks broken. The daemon therefore paints an explicit idle frame
// at session end and keeps a slow animation running while idle.
//
// Pure math + pixel fill so it can be unit-tested without a framebuffer.

#include <cstddef>
#include <cstdint>

namespace misterplex {

enum class IdleMode {
    Logo = 0,       // static centred chevron on a dark field
    Black = 1,      // flat black
    Screensaver = 2,// chevron slowly drifting to avoid CRT burn-in
    LastFrame = 3,  // leave whatever was on screen (legacy behaviour)
};

inline IdleMode idleModeFromBits(unsigned bits) {
    switch (bits & 3u) {
    case 1: return IdleMode::Black;
    case 2: return IdleMode::Screensaver;
    case 3: return IdleMode::LastFrame;
    default: return IdleMode::Logo;
    }
}

// Plex-ish palette: near-black background, amber mark.
constexpr uint8_t kIdleBgR = 0x1F, kIdleBgG = 0x23, kIdleBgB = 0x26;
constexpr uint8_t kIdleFgR = 0xE5, kIdleFgG = 0xA0, kIdleFgB = 0x0D;

// Screensaver drift: full cycle in this many phase steps. The mark never gets
// closer than kIdleMargin px to an edge, so it cannot be cropped by overscan.
constexpr int kIdlePhasePeriod = 1200;
constexpr int kIdleMargin = 8;

// Triangular wave in [0, span] — a drift that reverses instead of wrapping, so
// the mark never jumps across the screen.
inline int idleDrift(int phase, int span) {
    if (span <= 0)
        return 0;
    const int p = ((phase % kIdlePhasePeriod) + kIdlePhasePeriod) % kIdlePhasePeriod;
    const int half = kIdlePhasePeriod / 2;
    const int tri = p < half ? p : (kIdlePhasePeriod - p);
    return (tri * span) / half;
}

// Is (x,y) inside the chevron mark whose bounding box is [ox,oy]+[size,size]?
// The mark is a ">" stroke: two arms meeting at the right-hand vertex.
inline bool idleChevronHit(int x, int y, int ox, int oy, int size) {
    if (size <= 0)
        return false;
    const int lx = x - ox;
    const int ly = y - oy;
    if (lx < 0 || ly < 0 || lx >= size || ly >= size)
        return false;
    const int half = size / 2;
    const int stroke = size / 5 > 0 ? size / 5 : 1;
    // Distance from the two 45-degree arms, in "diagonal" units.
    const int d = ly <= half ? (lx - ly) : (lx - (size - 1 - ly));
    return d >= 0 && d < stroke;
}

struct IdleRenderState {
    bool blank = false;
    int size = 0;
    int ox = 0;
    int oy = 0;
};

inline IdleRenderState idleRenderState(int w, int h, IdleMode mode, int phase) {
    IdleRenderState s{};
    s.blank = (mode == IdleMode::Black);
    s.size = (w < h ? w : h) / 3;
    if (s.size < 4)
        s.size = 4;
    s.ox = (w - s.size) / 2;
    s.oy = (h - s.size) / 2;
    if (mode == IdleMode::Screensaver) {
        const int spanX = w - s.size - 2 * kIdleMargin;
        const int spanY = h - s.size - 2 * kIdleMargin;
        s.ox = kIdleMargin + idleDrift(phase, spanX);
        // Quarter-period offset so the drift traces a path, not a diagonal line.
        s.oy = kIdleMargin + idleDrift(phase + kIdlePhasePeriod / 4, spanY);
    }
    return s;
}

inline void idlePixelRgb(int x, int y, const IdleRenderState& s,
                         uint8_t& r, uint8_t& g, uint8_t& b) {
    const bool on = !s.blank && idleChevronHit(x, y, s.ox, s.oy, s.size);
    r = on ? kIdleFgR : (s.blank ? 0 : kIdleBgR);
    g = on ? kIdleFgG : (s.blank ? 0 : kIdleBgG);
    b = on ? kIdleFgB : (s.blank ? 0 : kIdleBgB);
}

inline uint8_t idleClamp8(int v) {
    return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
}

inline uint8_t idleRgbToY(int r, int g, int b) {
    return idleClamp8(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
}

inline uint8_t idleRgbToU(int r, int g, int b) {
    return idleClamp8(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
}

inline uint8_t idleRgbToV(int r, int g, int b) {
    return idleClamp8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
}

// Fill a packed RGB24 buffer with the idle image.
// `phase` advances one step per repaint; ignored unless mode is Screensaver.
// LastFrame is a no-op by design (caller must not repaint).
inline void renderIdleRgb24(uint8_t* rgb, int w, int h, IdleMode mode, int phase) {
    if (!rgb || w <= 0 || h <= 0 || mode == IdleMode::LastFrame)
        return;

    const IdleRenderState state = idleRenderState(w, h, mode, phase);
    uint8_t* p = rgb;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            uint8_t r = 0, g = 0, b = 0;
            idlePixelRgb(x, y, state, r, g, b);
            *p++ = r;
            *p++ = g;
            *p++ = b;
        }
    }
}

// Fill a planar I420/YUV420p buffer with the same idle image. This is the DDR
// frame-store format used by the C3 core; LastFrame remains a no-op.
inline bool renderIdleYuv420p(uint8_t* yuv, int w, int h, IdleMode mode, int phase) {
    if (!yuv || w <= 0 || h <= 0 || (w & 1) || (h & 1) || mode == IdleMode::LastFrame)
        return false;

    const IdleRenderState state = idleRenderState(w, h, mode, phase);
    uint8_t* yPlane = yuv;
    uint8_t* uPlane = yPlane + static_cast<size_t>(w) * static_cast<size_t>(h);
    uint8_t* vPlane = uPlane + static_cast<size_t>(w / 2) * static_cast<size_t>(h / 2);

    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            uint8_t r = 0, g = 0, b = 0;
            idlePixelRgb(x, y, state, r, g, b);
            yPlane[static_cast<size_t>(y) * static_cast<size_t>(w) + x] = idleRgbToY(r, g, b);
        }
    }

    for (int cy = 0; cy < h / 2; ++cy) {
        for (int cx = 0; cx < w / 2; ++cx) {
            int rSum = 0, gSum = 0, bSum = 0;
            for (int dy = 0; dy < 2; ++dy) {
                for (int dx = 0; dx < 2; ++dx) {
                    uint8_t r = 0, g = 0, b = 0;
                    idlePixelRgb(cx * 2 + dx, cy * 2 + dy, state, r, g, b);
                    rSum += r;
                    gSum += g;
                    bSum += b;
                }
            }
            const int r = (rSum + 2) / 4;
            const int g = (gSum + 2) / 4;
            const int b = (bSum + 2) / 4;
            const size_t ci = static_cast<size_t>(cy) * static_cast<size_t>(w / 2) + cx;
            uPlane[ci] = idleRgbToU(r, g, b);
            vPlane[ci] = idleRgbToV(r, g, b);
        }
    }
    return true;
}

} // namespace misterplex
