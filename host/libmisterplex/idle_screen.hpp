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

// Fill a packed RGB24 buffer with the idle image.
// `phase` advances one step per repaint; ignored unless mode is Screensaver.
// LastFrame is a no-op by design (caller must not repaint).
inline void renderIdleRgb24(uint8_t* rgb, int w, int h, IdleMode mode, int phase) {
    if (!rgb || w <= 0 || h <= 0 || mode == IdleMode::LastFrame)
        return;

    const bool blank = (mode == IdleMode::Black);
    const uint8_t bgR = blank ? 0 : kIdleBgR;
    const uint8_t bgG = blank ? 0 : kIdleBgG;
    const uint8_t bgB = blank ? 0 : kIdleBgB;

    int size = (w < h ? w : h) / 3;
    if (size < 4)
        size = 4;
    int ox = (w - size) / 2;
    int oy = (h - size) / 2;
    if (mode == IdleMode::Screensaver) {
        const int spanX = w - size - 2 * kIdleMargin;
        const int spanY = h - size - 2 * kIdleMargin;
        ox = kIdleMargin + idleDrift(phase, spanX);
        // Quarter-period offset so the drift traces a path, not a diagonal line.
        oy = kIdleMargin + idleDrift(phase + kIdlePhasePeriod / 4, spanY);
    }

    uint8_t* p = rgb;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const bool on = !blank && idleChevronHit(x, y, ox, oy, size);
            *p++ = on ? kIdleFgR : bgR;
            *p++ = on ? kIdleFgG : bgG;
            *p++ = on ? kIdleFgB : bgB;
        }
    }
}

} // namespace misterplex
