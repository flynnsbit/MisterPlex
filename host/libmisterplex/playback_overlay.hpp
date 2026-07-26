#pragma once
// Playback overlay renderer and API contract for input/transport workers.
//
// MediaPlayer exposes:
//   showPlaybackOverlay(PlaybackOverlayState state, positionMs, durationMs)
//     Show the on-screen transport overlay for a few seconds without changing
//     playback. Call this after play/pause/resume/stop or any control touch.
//   flashPlaybackSkip(deltaMs)
//     Show transient skip feedback ("30s >>" or "<< 30s") and refresh the
//     overlay timeout. Transport dispatch owns the actual seek/skip.
//
// The renderer is deliberately buffer-format agnostic. It can draw into RGB24
// or packed little-endian RGB565 and only touches the overlay dirty region; when
// hidden, render*() returns false without scanning the frame.

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace misterplex {

enum class PlaybackOverlayState {
    Playing,
    Paused,
    Stopped,
};

struct OverlayRect {
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;

    bool empty() const { return w <= 0 || h <= 0; }
};

class PlaybackOverlay {
public:
    static constexpr int64_t kVisibleMs = 3000;
    static constexpr int64_t kFadeMs = 500;
    static constexpr int64_t kSkipVisibleMs = 1200;

    void show(PlaybackOverlayState state, int64_t positionMs, int64_t durationMs) {
        showAt(state, positionMs, durationMs, monotonicMs());
    }

    void showAt(PlaybackOverlayState state, int64_t positionMs, int64_t durationMs,
                int64_t nowMs) {
        std::lock_guard<std::mutex> lock(mu_);
        state_ = state;
        positionMs_ = clampNonNegative(positionMs);
        durationMs_ = clampNonNegative(durationMs);
        shownAtMs_ = nowMs;
    }

    void setProgress(int64_t positionMs, int64_t durationMs) {
        std::lock_guard<std::mutex> lock(mu_);
        positionMs_ = clampNonNegative(positionMs);
        durationMs_ = clampNonNegative(durationMs);
    }

    void flashSkip(int64_t deltaMs, int64_t positionMs, int64_t durationMs) {
        flashSkipAt(deltaMs, positionMs, durationMs, monotonicMs());
    }

    void flashSkipAt(int64_t deltaMs, int64_t positionMs, int64_t durationMs, int64_t nowMs) {
        std::lock_guard<std::mutex> lock(mu_);
        positionMs_ = clampNonNegative(positionMs);
        durationMs_ = clampNonNegative(durationMs);
        skipDeltaMs_ = deltaMs;
        skipAtMs_ = nowMs;
        shownAtMs_ = nowMs;
    }

    bool visible() const { return visibleAt(monotonicMs()); }

    bool visibleAt(int64_t nowMs) const {
        Snapshot s = snapshot();
        return alphaFor(s, nowMs) > 0 || skipAlphaFor(s, nowMs) > 0;
    }

    OverlayRect dirtyBounds(int w, int h) const { return dirtyBoundsAt(w, h, monotonicMs()); }

    OverlayRect dirtyBoundsAt(int w, int h, int64_t nowMs) const {
        Snapshot s = snapshot();
        return dirtyBoundsFor(s, w, h, nowMs);
    }

    bool renderRgb24(uint8_t* rgb, int w, int h) const {
        return renderRgb24At(rgb, w, h, monotonicMs());
    }

    bool renderRgb24At(uint8_t* rgb, int w, int h, int64_t nowMs) const {
        if (!rgb || w <= 0 || h <= 0)
            return false;
        Snapshot s = snapshot();
        const OverlayRect dirty = dirtyBoundsFor(s, w, h, nowMs);
        if (dirty.empty())
            return false;
        Rgb24Target target{rgb, w, h};
        render(target, s, w, h, nowMs);
        return true;
    }

    bool renderRgb565Le(uint8_t* rgb565le, int w, int h) const {
        return renderRgb565LeAt(rgb565le, w, h, monotonicMs());
    }

    bool renderRgb565LeAt(uint8_t* rgb565le, int w, int h, int64_t nowMs) const {
        if (!rgb565le || w <= 0 || h <= 0)
            return false;
        Snapshot s = snapshot();
        const OverlayRect dirty = dirtyBoundsFor(s, w, h, nowMs);
        if (dirty.empty())
            return false;
        Rgb565LeTarget target{rgb565le, w, h};
        render(target, s, w, h, nowMs);
        return true;
    }

private:
    struct Color {
        uint8_t r;
        uint8_t g;
        uint8_t b;
    };

    struct Snapshot {
        PlaybackOverlayState state = PlaybackOverlayState::Stopped;
        int64_t positionMs = 0;
        int64_t durationMs = 0;
        int64_t shownAtMs = -kVisibleMs;
        int64_t skipAtMs = -kSkipVisibleMs;
        int64_t skipDeltaMs = 0;
    };

    struct Rgb24Target {
        uint8_t* p;
        int w;
        int h;

        Color get(int x, int y) const {
            const size_t i = (static_cast<size_t>(y) * w + x) * 3;
            return Color{p[i + 0], p[i + 1], p[i + 2]};
        }

        void set(int x, int y, Color c) {
            const size_t i = (static_cast<size_t>(y) * w + x) * 3;
            p[i + 0] = c.r;
            p[i + 1] = c.g;
            p[i + 2] = c.b;
        }
    };

    struct Rgb565LeTarget {
        uint8_t* p;
        int w;
        int h;

        Color get(int x, int y) const {
            const size_t i = (static_cast<size_t>(y) * w + x) * 2;
            const uint16_t v = static_cast<uint16_t>(p[i] | (p[i + 1] << 8));
            const uint8_t r5 = static_cast<uint8_t>((v >> 11) & 0x1f);
            const uint8_t g6 = static_cast<uint8_t>((v >> 5) & 0x3f);
            const uint8_t b5 = static_cast<uint8_t>(v & 0x1f);
            return Color{static_cast<uint8_t>((r5 << 3) | (r5 >> 2)),
                         static_cast<uint8_t>((g6 << 2) | (g6 >> 4)),
                         static_cast<uint8_t>((b5 << 3) | (b5 >> 2))};
        }

        void set(int x, int y, Color c) {
            const uint16_t v =
                static_cast<uint16_t>(((c.r & 0xf8) << 8) | ((c.g & 0xfc) << 3) | (c.b >> 3));
            const size_t i = (static_cast<size_t>(y) * w + x) * 2;
            p[i] = static_cast<uint8_t>(v & 0xff);
            p[i + 1] = static_cast<uint8_t>(v >> 8);
        }
    };

    static int64_t clampNonNegative(int64_t v) { return v < 0 ? 0 : v; }

    static int64_t monotonicMs() {
        const auto now = std::chrono::steady_clock::now().time_since_epoch();
        return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
    }

    Snapshot snapshot() const {
        std::lock_guard<std::mutex> lock(mu_);
        return Snapshot{state_, positionMs_, durationMs_, shownAtMs_, skipAtMs_, skipDeltaMs_};
    }

    static int alphaFor(const Snapshot& s, int64_t nowMs) {
        const int64_t age = nowMs - s.shownAtMs;
        if (age < 0 || age >= kVisibleMs)
            return 0;
        if (age <= kVisibleMs - kFadeMs)
            return 255;
        return std::max<int>(1, static_cast<int>(((kVisibleMs - age) * 255) / kFadeMs));
    }

    static int skipAlphaFor(const Snapshot& s, int64_t nowMs) {
        const int64_t age = nowMs - s.skipAtMs;
        if (age < 0 || age >= kSkipVisibleMs || s.skipDeltaMs == 0)
            return 0;
        if (age <= kSkipVisibleMs - 300)
            return 255;
        return std::max<int>(1, static_cast<int>(((kSkipVisibleMs - age) * 255) / 300));
    }

    static OverlayRect panelBounds(int w, int h) {
        const int margin = std::max(8, w / 32);
        const int ph = std::min(72, std::max(54, h / 4));
        return OverlayRect{margin, h - ph - margin, w - margin * 2, ph};
    }

    static OverlayRect dirtyBoundsFor(const Snapshot& s, int w, int h, int64_t nowMs) {
        if (w <= 0 || h <= 0)
            return {};
        OverlayRect out{};
        if (alphaFor(s, nowMs) > 0)
            out = panelBounds(w, h);
        if (skipAlphaFor(s, nowMs) > 0) {
            const int sw = std::min(w - 16, 116);
            const int sh = 28;
            OverlayRect skip{(w - sw) / 2, std::max(8, h / 2 - 30), sw, sh};
            out = unionRect(out, skip);
        }
        return out;
    }

    static OverlayRect unionRect(OverlayRect a, OverlayRect b) {
        if (a.empty())
            return b;
        if (b.empty())
            return a;
        const int x0 = std::min(a.x, b.x);
        const int y0 = std::min(a.y, b.y);
        const int x1 = std::max(a.x + a.w, b.x + b.w);
        const int y1 = std::max(a.y + a.h, b.y + b.h);
        return OverlayRect{x0, y0, x1 - x0, y1 - y0};
    }

    template <typename Target>
    static void blendPixel(Target& t, int x, int y, Color c, int alpha) {
        if (x < 0 || y < 0 || x >= t.w || y >= t.h || alpha <= 0)
            return;
        if (alpha >= 255) {
            t.set(x, y, c);
            return;
        }
        const Color d = t.get(x, y);
        const int inv = 255 - alpha;
        t.set(x, y, Color{static_cast<uint8_t>((c.r * alpha + d.r * inv) / 255),
                          static_cast<uint8_t>((c.g * alpha + d.g * inv) / 255),
                          static_cast<uint8_t>((c.b * alpha + d.b * inv) / 255)});
    }

    template <typename Target>
    static void fillRect(Target& t, int x, int y, int w, int h, Color c, int alpha) {
        const int x0 = std::max(0, x);
        const int y0 = std::max(0, y);
        const int x1 = std::min(t.w, x + w);
        const int y1 = std::min(t.h, y + h);
        for (int yy = y0; yy < y1; ++yy)
            for (int xx = x0; xx < x1; ++xx)
                blendPixel(t, xx, yy, c, alpha);
    }

    template <typename Target>
    static void strokeRect(Target& t, int x, int y, int w, int h, Color c, int alpha) {
        fillRect(t, x, y, w, 1, c, alpha);
        fillRect(t, x, y + h - 1, w, 1, c, alpha);
        fillRect(t, x, y, 1, h, c, alpha);
        fillRect(t, x + w - 1, y, 1, h, c, alpha);
    }

    static const uint8_t* glyph(char ch) {
        static constexpr uint8_t space[7] = {0, 0, 0, 0, 0, 0, 0};
        static constexpr uint8_t d0[7] = {0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e};
        static constexpr uint8_t d1[7] = {0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e};
        static constexpr uint8_t d2[7] = {0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f};
        static constexpr uint8_t d3[7] = {0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e};
        static constexpr uint8_t d4[7] = {0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02};
        static constexpr uint8_t d5[7] = {0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e};
        static constexpr uint8_t d6[7] = {0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e};
        static constexpr uint8_t d7[7] = {0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08};
        static constexpr uint8_t d8[7] = {0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e};
        static constexpr uint8_t d9[7] = {0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c};
        static constexpr uint8_t colon[7] = {0x00, 0x04, 0x04, 0x00, 0x04, 0x04, 0x00};
        static constexpr uint8_t lt[7] = {0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02};
        static constexpr uint8_t gt[7] = {0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08};
        static constexpr uint8_t minus[7] = {0, 0, 0, 0x1f, 0, 0, 0};
        static constexpr uint8_t a[7] = {0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11};
        static constexpr uint8_t d[7] = {0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e};
        static constexpr uint8_t e[7] = {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f};
        static constexpr uint8_t g[7] = {0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0f};
        static constexpr uint8_t i[7] = {0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e};
        static constexpr uint8_t l[7] = {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f};
        static constexpr uint8_t n[7] = {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11};
        static constexpr uint8_t o[7] = {0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e};
        static constexpr uint8_t p[7] = {0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10};
        static constexpr uint8_t s[7] = {0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e};
        static constexpr uint8_t t[7] = {0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04};
        static constexpr uint8_t u[7] = {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e};
        static constexpr uint8_t y[7] = {0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04};
        switch (ch) {
        case '0': return d0;
        case '1': return d1;
        case '2': return d2;
        case '3': return d3;
        case '4': return d4;
        case '5': return d5;
        case '6': return d6;
        case '7': return d7;
        case '8': return d8;
        case '9': return d9;
        case ':': return colon;
        case '<': return lt;
        case '>': return gt;
        case '-': return minus;
        case 'A': return a;
        case 'D': return d;
        case 'E': return e;
        case 'G': return g;
        case 'I': return i;
        case 'L': return l;
        case 'N': return n;
        case 'O': return o;
        case 'P': return p;
        case 'S': return s;
        case 'T': return t;
        case 'U': return u;
        case 'Y': return y;
        default: return space;
        }
    }

    static int textWidth(const char* text, int scale) {
        return static_cast<int>(std::strlen(text)) * 6 * scale - scale;
    }

    template <typename Target>
    static void drawText(Target& t, int x, int y, const char* text, int scale, Color c,
                         int alpha) {
        for (const char* p = text; *p; ++p) {
            const uint8_t* g = glyph(*p);
            for (int row = 0; row < 7; ++row) {
                for (int col = 0; col < 5; ++col) {
                    if ((g[row] & (1u << (4 - col))) == 0)
                        continue;
                    fillRect(t, x + col * scale, y + row * scale, scale, scale, c, alpha);
                }
            }
            x += 6 * scale;
        }
    }

    static void formatTime(int64_t ms, char (&out)[32]) {
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

    template <typename Target>
    static void drawIcon(Target& t, PlaybackOverlayState state, int cx, int cy, int alpha) {
        constexpr Color amber{255, 178, 32};
        if (state == PlaybackOverlayState::Playing) {
            for (int x = 0; x < 16; ++x) {
                const int half = x / 2;
                fillRect(t, cx - 5 + x, cy - half, 1, half * 2 + 1, amber, alpha);
            }
        } else if (state == PlaybackOverlayState::Paused) {
            fillRect(t, cx - 9, cy - 10, 6, 20, amber, alpha);
            fillRect(t, cx + 3, cy - 10, 6, 20, amber, alpha);
        } else {
            fillRect(t, cx - 9, cy - 9, 18, 18, amber, alpha);
        }
    }

    static const char* stateLabel(PlaybackOverlayState state) {
        switch (state) {
        case PlaybackOverlayState::Playing: return "PLAYING";
        case PlaybackOverlayState::Paused: return "PAUSED";
        case PlaybackOverlayState::Stopped: return "STOPPED";
        }
        return "STOPPED";
    }

    template <typename Target>
    static void render(Target& t, const Snapshot& s, int w, int h, int64_t nowMs) {
        const int alpha = alphaFor(s, nowMs);
        constexpr Color black{0, 0, 0};
        constexpr Color panelEdge{70, 74, 82};
        constexpr Color white{235, 238, 244};
        constexpr Color muted{130, 138, 150};
        constexpr Color amber{255, 178, 32};

        if (alpha > 0) {
            const OverlayRect p = panelBounds(w, h);
            fillRect(t, p.x, p.y, p.w, p.h, black, (170 * alpha) / 255);
            strokeRect(t, p.x, p.y, p.w, p.h, panelEdge, (150 * alpha) / 255);

            const int iconX = p.x + 22;
            const int labelY = p.y + 10;
            drawIcon(t, s.state, iconX, p.y + 20, alpha);
            drawText(t, iconX + 24, labelY, stateLabel(s.state), 1, white, alpha);

            char elapsed[32];
            char total[32];
            formatTime(s.positionMs, elapsed);
            formatTime(s.durationMs, total);
            drawText(t, p.x + 16, p.y + 34, elapsed, 1, white, alpha);
            const int totalW = textWidth(total, 1);
            drawText(t, p.x + p.w - 16 - totalW, p.y + 34, total, 1, muted, alpha);

            const int barX = p.x + 16;
            const int barY = p.y + p.h - 18;
            const int barW = p.w - 32;
            fillRect(t, barX, barY, barW, 6, Color{58, 63, 72}, (220 * alpha) / 255);
            int fillW = 0;
            if (s.durationMs > 0)
                fillW = static_cast<int>((static_cast<long long>(barW) *
                                          std::min(s.positionMs, s.durationMs)) /
                                         s.durationMs);
            fillW = std::max(0, std::min(barW, fillW));
            if (fillW > 0)
                fillRect(t, barX, barY, fillW, 6, amber, alpha);
            const int knobX = barX + fillW;
            fillRect(t, knobX - 2, barY - 2, 5, 10, white, alpha);
        }

        const int skipAlpha = skipAlphaFor(s, nowMs);
        if (skipAlpha > 0) {
            char text[24];
            const int64_t sec = std::min<int64_t>(
                9999, std::max<int64_t>(1, std::llabs(s.skipDeltaMs) / 1000));
            if (s.skipDeltaMs >= 0)
                std::snprintf(text, sizeof(text), "%lldS >>", static_cast<long long>(sec));
            else
                std::snprintf(text, sizeof(text), "<< %lldS", static_cast<long long>(sec));
            const int tw = textWidth(text, 2);
            const int boxW = std::min(w - 16, std::max(76, tw + 24));
            const int boxX = (w - boxW) / 2;
            const int boxY = std::max(8, h / 2 - 30);
            fillRect(t, boxX, boxY, boxW, 28, black, (190 * skipAlpha) / 255);
            strokeRect(t, boxX, boxY, boxW, 28, amber, skipAlpha);
            drawText(t, boxX + (boxW - tw) / 2, boxY + 7, text, 2, white, skipAlpha);
        }
    }

    mutable std::mutex mu_;
    PlaybackOverlayState state_ = PlaybackOverlayState::Stopped;
    int64_t positionMs_ = 0;
    int64_t durationMs_ = 0;
    int64_t shownAtMs_ = -kVisibleMs;
    int64_t skipAtMs_ = -kSkipVisibleMs;
    int64_t skipDeltaMs_ = 0;
};

} // namespace misterplex
