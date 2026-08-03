#pragma once
// plex_chrome_cmds — ARM→FPGA semantic command list (PLXC).
//
// 720p-first: default geometry is 1280×720. Fabric owns body_scale from
// HDMI_HEIGHT. ARM emits geometry in OUTPUT pixels and never writes overlay
// pixels when plane is live — the whole point is evacuating ARM ms/frame so
// decode can spend the 41.7 ms budget on 720p content, not HUD bake.
//
// Packing MUST match fpga/Plex_MiSTer/rtl/plex_chrome.sv.

#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

namespace misterplex {
namespace plex_chrome_cmds {

inline constexpr uint32_t kMagic = mailbox_abi::kPlxcMagic;
inline constexpr uint32_t kOffset = mailbox_abi::kPlxcOffset;
inline constexpr uint32_t kListOffset = mailbox_abi::kPlxlOffset;
inline constexpr int kMaxCmds = 48;
inline constexpr int kHitScan = 48; // match RTL HIT_SCAN
inline constexpr int kFontW = 8;
inline constexpr int kFontH = 8;
inline constexpr int kFontAdvance = 9; // 8 + 1 gap
// Product target raster (parameter, not a 480p-era leftover).
inline constexpr int kTargetOutW = 1280;
inline constexpr int kTargetOutH = 720;

enum class Op : uint8_t { End = 0, Rect = 1, Glyph = 2, RectPal = 3 };

enum class Pal : uint8_t {
    Panel = 0,
    Track = 1,
    Amber = 2,
    White = 3,
    Edge = 4,
    IdleBg = 5,
    IdleFg = 6,
};

inline int bodyScale(int hdmiH) {
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

inline uint64_t packGlyph(uint16_t x, uint16_t y, char code) {
    uint64_t w = 0;
    w |= static_cast<uint64_t>(static_cast<uint8_t>(Op::Glyph));
    w |= static_cast<uint64_t>(x) << 8;
    w |= static_cast<uint64_t>(y) << 24;
    w |= static_cast<uint64_t>(static_cast<uint8_t>(code)) << 40;
    return w;
}

inline uint64_t packRect(uint16_t x, uint16_t y, uint16_t w12, uint16_t h12) {
    uint64_t w = 0;
    w |= static_cast<uint64_t>(static_cast<uint8_t>(Op::Rect));
    w |= static_cast<uint64_t>(x) << 8;
    w |= static_cast<uint64_t>(y) << 24;
    w |= static_cast<uint64_t>(w12 & 0xFFFu) << 40;
    w |= static_cast<uint64_t>(h12 & 0xFFFu) << 52;
    return w;
}

inline uint64_t packRectPal(uint16_t x, uint16_t y, uint8_t w8, uint8_t h8, Pal pal) {
    uint64_t w = 0;
    w |= static_cast<uint64_t>(static_cast<uint8_t>(Op::RectPal));
    w |= static_cast<uint64_t>(x) << 8;
    w |= static_cast<uint64_t>(y) << 24;
    w |= static_cast<uint64_t>(w8) << 40;
    w |= static_cast<uint64_t>(h8) << 48;
    w |= static_cast<uint64_t>(static_cast<uint8_t>(pal)) << 56;
    return w;
}

// PLXC control qword (doorbell + 0x130)
inline uint64_t packPlxcCtrl(bool enable, unsigned cmdCount, uint16_t seq) {
    uint64_t w = static_cast<uint64_t>(kMagic);
    if (enable)
        w |= (1ull << 32);
    const unsigned c = std::min<unsigned>(cmdCount, static_cast<unsigned>(kMaxCmds));
    w |= (static_cast<uint64_t>(c) & 0x3FFFull) << 34;
    w |= static_cast<uint64_t>(seq) << 48;
    return w;
}

inline void appendText(std::vector<uint64_t>& out, int x, int y, const char* text, int scale) {
    if (!text)
        return;
    const int adv = kFontAdvance * scale;
    for (const char* p = text; *p; ++p) {
        if (out.size() >= static_cast<size_t>(kMaxCmds))
            return;
        out.push_back(packGlyph(static_cast<uint16_t>(x), static_cast<uint16_t>(y), *p));
        x += adv;
    }
}

inline void formatTime(int64_t ms, char (&out)[32]) {
    int64_t sec = ms / 1000;
    const int64_t h = sec / 3600;
    sec %= 3600;
    const int64_t m = sec / 60;
    const int64_t s = sec % 60;
    if (h > 0)
        std::snprintf(out, 32, "%lld:%02lld:%02lld", static_cast<long long>(h),
                      static_cast<long long>(m), static_cast<long long>(s));
    else
        std::snprintf(out, 32, "%lld:%02lld", static_cast<long long>(m),
                      static_cast<long long>(s));
}

inline const char* stateLabel(PlaybackOverlayState st) {
    switch (st) {
    case PlaybackOverlayState::Playing: return "PLAYING";
    case PlaybackOverlayState::Paused: return "PAUSED";
    case PlaybackOverlayState::Stopped: return "STOPPED";
    }
    return "STOPPED";
}

// Build the live HUD the parent captured: state + title + two timecodes + bar.
// Coordinates are OUTPUT pixels; scale from HDMI_H.
struct BuildArgs {
    int outW = kTargetOutW; // 1280 — 720p-first
    int outH = kTargetOutH; // 720
    PlaybackOverlayState state = PlaybackOverlayState::Stopped;
    int64_t positionMs = 0;
    int64_t durationMs = 0;
    const char* title = nullptr; // optional, truncated
};

inline std::vector<uint64_t> buildPlaybackHud(const BuildArgs& a) {
    std::vector<uint64_t> cmds;
    cmds.reserve(40);
    const int scale = bodyScale(a.outH);
    const int margin = std::max(8, a.outW / 32);
    const int ph = std::min(72 * scale / 2, std::max(54, a.outH / 4));
    const int px = margin;
    const int py = a.outH - ph - margin;
    const int pw = a.outW - margin * 2;

    // Panel background (may exceed 255 — use RECT w12)
    cmds.push_back(packRect(static_cast<uint16_t>(px), static_cast<uint16_t>(py),
                            static_cast<uint16_t>(pw), static_cast<uint16_t>(ph)));

    const int labelY = py + 10;
    const int textX = px + 16;
    appendText(cmds, textX, labelY, stateLabel(a.state), scale);

    if (a.title && a.title[0]) {
        char tbuf[20];
        std::snprintf(tbuf, sizeof(tbuf), "%s", a.title);
        // place title to the right of state
        const int titleX = textX + static_cast<int>(std::strlen(stateLabel(a.state))) *
                                       kFontAdvance * scale +
                           16;
        appendText(cmds, titleX, labelY, tbuf, scale);
    }

    char elapsed[32];
    char total[32];
    formatTime(a.positionMs, elapsed);
    formatTime(a.durationMs, total);
    const int timeY = py + 34;
    appendText(cmds, px + 16, timeY, elapsed, scale);
    const int totalW = static_cast<int>(std::strlen(total)) * kFontAdvance * scale;
    appendText(cmds, px + pw - 16 - totalW, timeY, total, scale);

    // Progress track + fill (palette rects, w/h <= 255 → clamp segments if needed)
    const int barX = px + 16;
    const int barY = py + ph - 18;
    const int barW = pw - 32;
    const int barH = 6;
    // Track: may be wide — emit as RECT (dark panel is OK) or chunked pal
    cmds.push_back(packRect(static_cast<uint16_t>(barX), static_cast<uint16_t>(barY),
                            static_cast<uint16_t>(barW), static_cast<uint16_t>(barH)));
    int fillW = 0;
    if (a.durationMs > 0)
        fillW = static_cast<int>((static_cast<long long>(barW) *
                                  std::min(a.positionMs, a.durationMs)) /
                                 a.durationMs);
    fillW = std::max(0, std::min(barW, fillW));
    if (fillW > 0) {
        // Amber fill via RECT_PAL chunks of <=255
        int x = barX;
        int remain = fillW;
        while (remain > 0 && cmds.size() < static_cast<size_t>(kMaxCmds)) {
            const int chunk = std::min(255, remain);
            cmds.push_back(packRectPal(static_cast<uint16_t>(x), static_cast<uint16_t>(barY),
                                       static_cast<uint8_t>(chunk),
                                       static_cast<uint8_t>(barH), Pal::Amber));
            x += chunk;
            remain -= chunk;
        }
    }

    if (cmds.size() > static_cast<size_t>(kMaxCmds))
        cmds.resize(static_cast<size_t>(kMaxCmds));
    return cmds;
}

// Fail-closed live gate.
inline bool chromePlaneLive(bool confWants, bool hwPresent) {
    return confWants && hwPresent;
}

} // namespace plex_chrome_cmds
} // namespace misterplex
