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
// Layout is resolution-independent: metrics are fractions of the *buffer* size.
// Default path: present/coded bank (plane=0 F1 bake) — bodyScale floor 2 for
// even-row cull. Native path: setOutputRasterLayout(true) + pass HDMI W×H so
// metrics come from computeOutputChromeLayout (scale up to 6 @1440p). See
// docs/osd-native-raster-arm-design.md.
//
// The renderer is buffer-format agnostic (RGB24, RGB565LE, BGRA32, YUV420p) and
// only touches the overlay dirty region; when hidden, render*() returns false
// without scanning the frame.

#include "libmisterplex/mister_video_mode.hpp"
#include "libmisterplex/overlay_font_24x32.hpp"

#include <algorithm>
#include <atomic>
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

// Font cells (CC0 hand-authored geometric bitmaps for MiSTerPlex).
// HARD CONSTRAINT from present_core.sv: scanout fetches only even store rows
// (STORE_Y_SCALE=2.0 with FRAME_H=480). Drawing a glyph row as a single content
// row (scale=1) deletes every other glyph row → silent character corruption
// (e.g. 8→0, 6→C). bodyScale must be >= 2 so each glyph row occupies ≥2 content
// rows and one always survives. Text y-origins are snapped to even rows.
enum class OverlayFontId : uint8_t { Small8x13 = 0, Large12x16 = 1, Hires24x32 = 2 };

static constexpr int kOverlayFontSmallW = 8;
static constexpr int kOverlayFontSmallH = 13;
static constexpr int kOverlayFontSmallAdvance = 9;
static constexpr int kOverlayFontLargeW = 12;
static constexpr int kOverlayFontLargeH = 16;
static constexpr int kOverlayFontLargeAdvance = 13;
static constexpr int kOverlayFontHiresW = overlay_font_24x32::kW;
static constexpr int kOverlayFontHiresH = overlay_font_24x32::kH;
static constexpr int kOverlayFontHiresAdvance = overlay_font_24x32::kAdvance;
static constexpr int kOverlayMinScale = 2; // vertical (and default body) floor

// Resolution-scaled chrome metrics from buffer W×H (present/coded canvas).
struct OverlayLayoutMetrics {
    int margin = 8;
    int panelH = 64;
    int bodyScale = kOverlayMinScale; // >=2 — odd-row cull survival
    int titleScale = kOverlayMinScale;
    int iconScale = kOverlayMinScale;
    OverlayFontId fontId = OverlayFontId::Small8x13;
    int glyphW = kOverlayFontSmallW;
    int glyphH = kOverlayFontSmallH;
    int glyphAdvance = kOverlayFontSmallAdvance;
    int barH = 6;
    int barBottomPad = 16;
    int labelTop = 8;
    int iconCy = 18;
    int timeTop = 32;
    int skipBoxH = 28;
    int noticeBoxH = 28;

    int textCellH() const { return glyphH * bodyScale; }
    int textCellW() const { return glyphW * bodyScale; }

    static OverlayLayoutMetrics compute(int w, int h) {
        OverlayLayoutMetrics m;
        if (w <= 0 || h <= 0)
            return m;
        m.margin = std::max(6, w / 40);
        // Scale floor 2 (even-row cull). Taller canvases may use 3.
        // Cap 3: bank/F1 path only — native HDMI uses fromOutputLayout.
        m.bodyScale = std::max(kOverlayMinScale, h >= 720 ? 3 : 2);
        m.titleScale = m.bodyScale;
        m.iconScale = std::max(kOverlayMinScale, h >= 720 ? 3 : 2);
        // 12×16 only when h>=480 at bodyScale==2 (product bank height).
        // w is NOT a selector: STOP/idle always authors h=480 via
        // plex480pDdrFrameGeometry(); a w>=600 clause would only fire on a
        // short-H wide canvas and would mask that defect. Unit fixtures at
        // 320×240 correctly keep 8×13.
        // Product bank 624×480: 24×32 @ scale2 → textCellH=64 → ~32 unique
        // store rows after even-row cull (vs 16 for 12×16@2). Not NN-of-12x16.
        if (h >= 480 && m.bodyScale == 2) {
            m.fontId = OverlayFontId::Hires24x32;
            m.glyphW = kOverlayFontHiresW;
            m.glyphH = kOverlayFontHiresH;
            m.glyphAdvance = kOverlayFontHiresAdvance;
        } else {
            m.fontId = OverlayFontId::Small8x13;
            m.glyphW = kOverlayFontSmallW;
            m.glyphH = kOverlayFontSmallH;
            m.glyphAdvance = kOverlayFontSmallAdvance;
        }
        finishVertical(m, h);
        return m;
    }

    // Native post-ascal plane authoring (HDMI W×H). Uses computeOutputChromeLayout
    // so bodyScale tracks output height (6 @1440, 2 @480/240). Must not be used
    // for F1 bank bake — bank stays on compute().
    static OverlayLayoutMetrics fromOutputLayout(int outW, int outH) {
        OverlayLayoutMetrics m;
        if (outW <= 0 || outH <= 0)
            return m;
        const OutputChromeLayout L = computeOutputChromeLayout(outW, outH);
        m.margin = L.margin;
        m.panelH = L.panelH;
        m.bodyScale = std::max(kOverlayMinScale, L.bodyScale);
        m.titleScale = m.bodyScale;
        m.iconScale = m.bodyScale;
        if (L.useLargeFont) {
            m.fontId = OverlayFontId::Large12x16;
            m.glyphW = kOverlayFontLargeW;
            m.glyphH = kOverlayFontLargeH;
            m.glyphAdvance = kOverlayFontLargeAdvance;
        } else {
            m.fontId = OverlayFontId::Small8x13;
            m.glyphW = kOverlayFontSmallW;
            m.glyphH = kOverlayFontSmallH;
            m.glyphAdvance = kOverlayFontSmallAdvance;
        }
        finishVertical(m, outH);
        return m;
    }

    static OverlayLayoutMetrics resolve(int w, int h, bool outputRaster) {
        return outputRaster ? fromOutputLayout(w, h) : compute(w, h);
    }

private:
    static void finishVertical(OverlayLayoutMetrics& m, int h) {
        const int textH = m.glyphH * m.bodyScale;
        const int need = 8 + textH + 4 + textH + 12 + std::max(4, 6);
        if (m.panelH <= 0)
            m.panelH = std::max(need, std::min(h / 3, std::max(64, h / 4)));
        if (m.panelH < need)
            m.panelH = need;
        if (m.panelH > h - 2 * m.margin)
            m.panelH = std::max(need, h - 2 * m.margin);
        m.barH = std::max(4, m.panelH / 12);
        m.barBottomPad = 10 + m.barH;
        m.labelTop = 6;
        m.labelTop &= ~1;
        m.iconCy = m.labelTop + textH / 2;
        m.timeTop = m.labelTop + textH + 4;
        m.timeTop &= ~1;
        m.skipBoxH = std::max(28, textH + 12);
        m.noticeBoxH = m.skipBoxH;
    }
};

class PlaybackOverlay {
public:
    static constexpr int64_t kVisibleMs = 3000;
    static constexpr int64_t kFadeMs = 500;
    static constexpr int64_t kSkipVisibleMs = 1200;

    // plane=1 authoring: layout from HDMI W×H (computeOutputChromeLayout).
    // Default false = F1 bank bake (compute). Safe degrade on old RBF.
    void setOutputRasterLayout(bool on) { outputRasterLayout_.store(on, std::memory_order_relaxed); }
    bool outputRasterLayout() const { return outputRasterLayout_.load(std::memory_order_relaxed); }

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

    // Media title drawn in the empty panel band (right of state label). Empty clears.
    void setTitle(const char* title) {
        std::lock_guard<std::mutex> lock(mu_);
        titleText_[0] = '\0';
        if (title && title[0]) {
            std::snprintf(titleText_, sizeof(titleText_), "%s", title);
            titleText_[sizeof(titleText_) - 1] = '\0';
        }
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

    static constexpr int64_t kNoticeVisibleMs = 8000;

    void flashNotice(const char* text) { flashNoticeAt(text, monotonicMs()); }

    void flashNoticeAt(const char* text, int64_t nowMs) {
        std::lock_guard<std::mutex> lock(mu_);
        noticeText_[0] = '\0';
        if (text && text[0]) {
            std::snprintf(noticeText_, sizeof(noticeText_), "%s", text);
            noticeText_[sizeof(noticeText_) - 1] = '\0';
        }
        noticeAtMs_ = nowMs;
    }

    bool visible() const { return visibleAt(monotonicMs()); }

    bool visibleAt(int64_t nowMs) const {
        Snapshot s = snapshot();
        return alphaFor(s, nowMs) > 0 || skipAlphaFor(s, nowMs) > 0 || noticeAlphaFor(s, nowMs) > 0;
    }

    OverlayRect dirtyBounds(int w, int h) const { return dirtyBoundsAt(w, h, monotonicMs()); }

    OverlayRect dirtyBoundsAt(int w, int h, int64_t nowMs) const {
        Snapshot s = snapshot();
        return dirtyBoundsFor(s, w, h, nowMs, outputRasterLayout());
    }

    static OverlayLayoutMetrics layoutMetrics(int w, int h) {
        return OverlayLayoutMetrics::compute(w, h);
    }

    OverlayLayoutMetrics activeLayoutMetrics(int w, int h) const {
        return OverlayLayoutMetrics::resolve(w, h, outputRasterLayout());
    }

    bool renderRgb24(uint8_t* rgb, int w, int h) const {
        return renderRgb24At(rgb, w, h, monotonicMs());
    }

    bool renderRgb24At(uint8_t* rgb, int w, int h, int64_t nowMs) const {
        if (!rgb || w <= 0 || h <= 0)
            return false;
        Snapshot s = snapshot();
        const bool out = outputRasterLayout();
        const OverlayRect dirty = dirtyBoundsFor(s, w, h, nowMs, out);
        if (dirty.empty())
            return false;
        Rgb24Target target{rgb, w, h};
        render(target, s, w, h, nowMs, out);
        return true;
    }

    bool renderRgb565Le(uint8_t* rgb565le, int w, int h) const {
        return renderRgb565LeAt(rgb565le, w, h, monotonicMs());
    }

    bool renderRgb565LeAt(uint8_t* rgb565le, int w, int h, int64_t nowMs) const {
        if (!rgb565le || w <= 0 || h <= 0)
            return false;
        Snapshot s = snapshot();
        const bool out = outputRasterLayout();
        const OverlayRect dirty = dirtyBoundsFor(s, w, h, nowMs, out);
        if (dirty.empty())
            return false;
        Rgb565LeTarget target{rgb565le, w, h};
        render(target, s, w, h, nowMs, out);
        return true;
    }

    bool renderBgra32(uint8_t* bgra, int w, int h) const {
        return renderBgra32At(bgra, w, h, monotonicMs());
    }

    bool renderBgra32At(uint8_t* bgra, int w, int h, int64_t nowMs) const {
        if (!bgra || w <= 0 || h <= 0)
            return false;
        Snapshot s = snapshot();
        const bool out = outputRasterLayout();
        const OverlayRect dirty = dirtyBoundsFor(s, w, h, nowMs, out);
        if (dirty.empty())
            return false;
        Bgra32Target target{bgra, w, h};
        render(target, s, w, h, nowMs, out);
        return true;
    }

    bool renderYuv420p(uint8_t* yuv, int w, int h) const {
        return renderYuv420pAt(yuv, w, h, monotonicMs());
    }

    bool renderYuv420pAt(uint8_t* yuv, int w, int h, int64_t nowMs) const {
        if (!yuv || w <= 0 || h <= 0 || (w & 1) || (h & 1))
            return false;
        Snapshot s = snapshot();
        const bool out = outputRasterLayout();
        const OverlayRect dirty = dirtyBoundsFor(s, w, h, nowMs, out);
        if (dirty.empty())
            return false;
        Yuv420pTarget target{yuv, w, h};
        render(target, s, w, h, nowMs, out);
        return true;
    }

    static OverlayRect panelBounds(int w, int h) {
        return panelBounds(w, h, false);
    }

    static OverlayRect panelBounds(int w, int h, bool outputRaster) {
        const OverlayLayoutMetrics m = OverlayLayoutMetrics::resolve(w, h, outputRaster);
        // Even top edge so labelTop offsets keep text on a deterministic phase.
        int py = h - m.panelH - m.margin;
        py &= ~1;
        int ph = m.panelH;
        if (py + ph > h)
            ph = h - py;
        return OverlayRect{m.margin, py, w - m.margin * 2, ph};
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
        int64_t noticeAtMs = -kNoticeVisibleMs;
        char noticeText[32]{};
        char titleText[64]{};
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

    struct Bgra32Target {
        uint8_t* p;
        int w;
        int h;

        Color get(int x, int y) const {
            const size_t i = (static_cast<size_t>(y) * w + x) * 4;
            return Color{p[i + 2], p[i + 1], p[i + 0]};
        }

        void set(int x, int y, Color c) {
            const size_t i = (static_cast<size_t>(y) * w + x) * 4;
            p[i + 0] = c.b;
            p[i + 1] = c.g;
            p[i + 2] = c.r;
            p[i + 3] = 0xff;
        }
    };

    struct Yuv420pTarget {
        uint8_t* p;
        int w;
        int h;

        uint8_t* yPlane() const { return p; }
        uint8_t* uPlane() const { return p + static_cast<size_t>(w) * static_cast<size_t>(h); }
        uint8_t* vPlane() const {
            return uPlane() + static_cast<size_t>(w / 2) * static_cast<size_t>(h / 2);
        }

        static uint8_t clamp8(int v) {
            return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
        }
        static uint8_t rgbToY(int r, int g, int b) {
            return clamp8(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
        }
        static uint8_t rgbToU(int r, int g, int b) {
            return clamp8(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
        }
        static uint8_t rgbToV(int r, int g, int b) {
            return clamp8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
        }
        static void yuvToRgb(uint8_t y, uint8_t u, uint8_t v, uint8_t& r, uint8_t& g, uint8_t& b) {
            const int uu = static_cast<int>(u) - 128;
            const int vv = static_cast<int>(v) - 128;
            r = clamp8((static_cast<int>(y) * 256 + 359 * vv) >> 8);
            g = clamp8((static_cast<int>(y) * 256 - 88 * uu - 183 * vv) >> 8);
            b = clamp8((static_cast<int>(y) * 256 + 454 * uu) >> 8);
        }

        Color get(int x, int y) const {
            const uint8_t Y = yPlane()[static_cast<size_t>(y) * w + x];
            const uint8_t U = uPlane()[static_cast<size_t>(y / 2) * (w / 2) + (x / 2)];
            const uint8_t V = vPlane()[static_cast<size_t>(y / 2) * (w / 2) + (x / 2)];
            Color c{};
            yuvToRgb(Y, U, V, c.r, c.g, c.b);
            return c;
        }

        void set(int x, int y, Color c) {
            yPlane()[static_cast<size_t>(y) * w + x] = rgbToY(c.r, c.g, c.b);
            const size_t ci = static_cast<size_t>(y / 2) * (w / 2) + (x / 2);
            uPlane()[ci] = rgbToU(c.r, c.g, c.b);
            vPlane()[ci] = rgbToV(c.r, c.g, c.b);
        }
    };

    static int64_t clampNonNegative(int64_t v) { return v < 0 ? 0 : v; }

    static int64_t monotonicMs() {
        const auto now = std::chrono::steady_clock::now().time_since_epoch();
        return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
    }

    Snapshot snapshot() const {
        std::lock_guard<std::mutex> lock(mu_);
        Snapshot s;
        s.state = state_;
        s.positionMs = positionMs_;
        s.durationMs = durationMs_;
        s.shownAtMs = shownAtMs_;
        s.skipAtMs = skipAtMs_;
        s.skipDeltaMs = skipDeltaMs_;
        s.noticeAtMs = noticeAtMs_;
        std::memcpy(s.noticeText, noticeText_, sizeof(s.noticeText));
        std::memcpy(s.titleText, titleText_, sizeof(s.titleText));
        return s;
    }

    static int alphaFor(const Snapshot& s, int64_t nowMs) {
        // Paused and Stopped transport chrome stay up until the next state
        // change. A 3s auto-hide (kVisibleMs) wiped PAUSED after grabber
        // warm-up (Test B) and also dropped STOPPED on the idle path so a late
        // capture saw logo-only. Playing still uses the transient timeout.
        if (s.state == PlaybackOverlayState::Paused ||
            s.state == PlaybackOverlayState::Stopped) {
            if (s.shownAtMs < 0)
                return 0;
            return 255;
        }
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

    static int noticeAlphaFor(const Snapshot& s, int64_t nowMs) {
        if (s.noticeText[0] == '\0')
            return 0;
        const int64_t age = nowMs - s.noticeAtMs;
        if (age < 0 || age >= kNoticeVisibleMs)
            return 0;
        if (age <= kNoticeVisibleMs - kFadeMs)
            return 255;
        return std::max<int>(1, static_cast<int>(((kNoticeVisibleMs - age) * 255) / kFadeMs));
    }

    static OverlayRect dirtyBoundsFor(const Snapshot& s, int w, int h, int64_t nowMs,
                                      bool outputRaster = false) {
        if (w <= 0 || h <= 0)
            return {};
        const OverlayLayoutMetrics m = OverlayLayoutMetrics::resolve(w, h, outputRaster);
        OverlayRect out{};
        if (alphaFor(s, nowMs) > 0)
            out = panelBounds(w, h, outputRaster);
        if (skipAlphaFor(s, nowMs) > 0) {
            const int sw = std::min(w - 16, std::max(116, 40 * m.titleScale + 76));
            OverlayRect skip{(w - sw) / 2, std::max(8, h / 2 - m.skipBoxH - 2), sw, m.skipBoxH};
            out = unionRect(out, skip);
        }
        if (noticeAlphaFor(s, nowMs) > 0) {
            const int tw = textWidth(s.noticeText, m);
            const int boxW = std::min(w - 16, std::max(76, tw + 24));
            OverlayRect notice{(w - boxW) / 2, std::max(8, h / 5), boxW, m.noticeBoxH};
            out = unionRect(out, notice);
        }
        if (!out.empty()) {
            if (out.x < 0) {
                out.w += out.x;
                out.x = 0;
            }
            if (out.y < 0) {
                out.h += out.y;
                out.y = 0;
            }
            if (out.x + out.w > w)
                out.w = w - out.x;
            if (out.y + out.h > h)
                out.h = h - out.y;
            if (out.w <= 0 || out.h <= 0)
                return {};
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
    static void fillRect(Target& t, int x, int y, int ww, int hh, Color c, int alpha) {
        const int x0 = std::max(0, x);
        const int y0 = std::max(0, y);
        const int x1 = std::min(t.w, x + ww);
        const int y1 = std::min(t.h, y + hh);
        for (int yy = y0; yy < y1; ++yy)
            for (int xx = x0; xx < x1; ++xx)
                blendPixel(t, xx, yy, c, alpha);
    }

    template <typename Target>
    static void strokeRect(Target& t, int x, int y, int ww, int hh, Color c, int alpha) {
        fillRect(t, x, y, ww, 1, c, alpha);
        fillRect(t, x, y + hh - 1, ww, 1, c, alpha);
        fillRect(t, x, y, 1, hh, c, alpha);
        fillRect(t, x + ww - 1, y, 1, hh, c, alpha);
    }

    // 8×13 bitmaps, MSB = left column. Drawn with bodyScale>=2 (odd-row cull).
    static const uint8_t* glyph(char ch) {
        static constexpr uint8_t space[13] = {};
        // Digits and letters needed for transport chrome.
        static constexpr uint8_t d0[13] = {0x00, 0x3C, 0x66, 0xC3, 0xC3, 0xC3, 0xC3,
                                          0xC3, 0xC3, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t d1[13] = {0x00, 0x18, 0x38, 0x18, 0x18, 0x18, 0x18,
                                          0x18, 0x18, 0x18, 0x7E, 0x00, 0x00};
        static constexpr uint8_t d2[13] = {0x00, 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30,
                                          0x60, 0xC0, 0xC0, 0xFE, 0x00, 0x00};
        static constexpr uint8_t d3[13] = {0x00, 0x3C, 0x66, 0x06, 0x06, 0x1C, 0x06,
                                          0x06, 0x06, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t d4[13] = {0x00, 0x0C, 0x1C, 0x3C, 0x6C, 0xCC, 0xFE,
                                          0x0C, 0x0C, 0x0C, 0x0C, 0x00, 0x00};
        static constexpr uint8_t d5[13] = {0x00, 0x7E, 0x60, 0x60, 0x7C, 0x06, 0x06,
                                          0x06, 0x06, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t d6[13] = {0x00, 0x1C, 0x30, 0x60, 0x60, 0x7C, 0x66,
                                          0x66, 0x66, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t d7[13] = {0x00, 0xFE, 0x06, 0x0C, 0x0C, 0x18, 0x18,
                                          0x30, 0x30, 0x30, 0x30, 0x00, 0x00};
        static constexpr uint8_t d8[13] = {0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x66,
                                          0x66, 0x66, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t d9[13] = {0x00, 0x3C, 0x66, 0x66, 0x66, 0x3E, 0x06,
                                          0x06, 0x06, 0x0C, 0x38, 0x00, 0x00};
        static constexpr uint8_t colon[13] = {0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00,
                                             0x18, 0x18, 0x00, 0x00, 0x00, 0x00};
        static constexpr uint8_t lt[13] = {0x00, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0,
                                          0x60, 0x30, 0x18, 0x0C, 0x06, 0x00};
        static constexpr uint8_t gt[13] = {0x00, 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06,
                                          0x0C, 0x18, 0x30, 0x60, 0xC0, 0x00};
        static constexpr uint8_t minus[13] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x7E,
                                             0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
        static constexpr uint8_t a[13] = {0x00, 0x3C, 0x66, 0x66, 0x66, 0x7E, 0x66,
                                         0x66, 0x66, 0x66, 0x66, 0x00, 0x00};
        static constexpr uint8_t d[13] = {0x00, 0x78, 0x6C, 0x66, 0x66, 0x66, 0x66,
                                         0x66, 0x66, 0x6C, 0x78, 0x00, 0x00};
        static constexpr uint8_t e[13] = {0x00, 0x7E, 0x60, 0x60, 0x60, 0x7C, 0x60,
                                         0x60, 0x60, 0x60, 0x7E, 0x00, 0x00};
        static constexpr uint8_t g[13] = {0x00, 0x3C, 0x66, 0xC0, 0xC0, 0xDE, 0xC6,
                                         0xC6, 0xC6, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t i[13] = {0x00, 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18,
                                         0x18, 0x18, 0x18, 0x3C, 0x00, 0x00};
        static constexpr uint8_t l[13] = {0x00, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60,
                                         0x60, 0x60, 0x60, 0x7E, 0x00, 0x00};
        static constexpr uint8_t n[13] = {0x00, 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66,
                                         0x66, 0x66, 0x66, 0x66, 0x00, 0x00};
        static constexpr uint8_t o[13] = {0x00, 0x3C, 0x66, 0xC3, 0xC3, 0xC3, 0xC3,
                                         0xC3, 0xC3, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t p[13] = {0x00, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x60,
                                         0x60, 0x60, 0x60, 0x60, 0x00, 0x00};
        static constexpr uint8_t s[13] = {0x00, 0x3C, 0x66, 0x60, 0x60, 0x3C, 0x06,
                                         0x06, 0x06, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t t[13] = {0x00, 0xFF, 0x18, 0x18, 0x18, 0x18, 0x18,
                                         0x18, 0x18, 0x18, 0x18, 0x00, 0x00};
        static constexpr uint8_t u[13] = {0x00, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
                                         0x66, 0x66, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t y[13] = {0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18,
                                         0x18, 0x18, 0x18, 0x18, 0x00, 0x00};
        // Extra chars used in skip/notice strings.
        static constexpr uint8_t f[13] = {0x00, 0x7E, 0x60, 0x60, 0x60, 0x7C, 0x60,
                                         0x60, 0x60, 0x60, 0x60, 0x00, 0x00};
        static constexpr uint8_t r[13] = {0x00, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x6C,
                                         0x66, 0x66, 0x66, 0x66, 0x00, 0x00};
        static constexpr uint8_t c[13] = {0x00, 0x3C, 0x66, 0xC0, 0xC0, 0xC0, 0xC0,
                                         0xC0, 0xC0, 0x66, 0x3C, 0x00, 0x00};
        static constexpr uint8_t m[13] = {0x00, 0xC3, 0xE7, 0xFF, 0xDB, 0xC3, 0xC3,
                                         0xC3, 0xC3, 0xC3, 0xC3, 0x00, 0x00};
        static constexpr uint8_t w[13] = {0x00, 0xC3, 0xC3, 0xC3, 0xC3, 0xC3, 0xDB,
                                         0xFF, 0xE7, 0xC3, 0xC3, 0x00, 0x00};
        static constexpr uint8_t h[13] = {0x00, 0x66, 0x66, 0x66, 0x66, 0x7E, 0x66,
                                         0x66, 0x66, 0x66, 0x66, 0x00, 0x00};
        static constexpr uint8_t k[13] = {0x00, 0x66, 0x6C, 0x78, 0x70, 0x70, 0x78,
                                         0x6C, 0x66, 0x66, 0x66, 0x00, 0x00};
        static constexpr uint8_t b[13] = {0x00, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x66,
                                         0x66, 0x66, 0x66, 0x7C, 0x00, 0x00};
        static constexpr uint8_t v[13] = {0x00, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
                                         0x66, 0x3C, 0x18, 0x18, 0x00, 0x00};
        static constexpr uint8_t j[13] = {0x00, 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C,
                                         0x0C, 0x0C, 0x6C, 0x38, 0x00, 0x00};
        static constexpr uint8_t q[13] = {0x00, 0x3C, 0x66, 0xC3, 0xC3, 0xC3, 0xC3,
                                         0xDB, 0xCF, 0x66, 0x3D, 0x00, 0x00};
        static constexpr uint8_t x[13] = {0x00, 0xC3, 0x66, 0x3C, 0x18, 0x18, 0x3C,
                                         0x66, 0xC3, 0xC3, 0xC3, 0x00, 0x00};
        static constexpr uint8_t z[13] = {0x00, 0xFF, 0x06, 0x0C, 0x18, 0x18, 0x30,
                                         0x60, 0xC0, 0xC0, 0xFF, 0x00, 0x00};
        static constexpr uint8_t slash[13] = {0x00, 0x06, 0x06, 0x0C, 0x0C, 0x18, 0x18,
                                             0x30, 0x30, 0x60, 0x60, 0x00, 0x00};
        if (ch >= 'a' && ch <= 'z')
            ch = static_cast<char>(ch - 'a' + 'A');
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
        case '/': return slash;
        case 'A': return a;
        case 'B': return b;
        case 'C': return c;
        case 'D': return d;
        case 'E': return e;
        case 'F': return f;
        case 'G': return g;
        case 'H': return h;
        case 'I': return i;
        case 'J': return j;
        case 'K': return k;
        case 'L': return l;
        case 'M': return m;
        case 'N': return n;
        case 'O': return o;
        case 'P': return p;
        case 'Q': return q;
        case 'R': return r;
        case 'S': return s;
        case 'T': return t;
        case 'U': return u;
        case 'V': return v;
        case 'W': return w;
        case 'X': return x;
        case 'Y': return y;
        case 'Z': return z;
        default: return space;
        }
    }

    static int textWidth(const char* text, const OverlayLayoutMetrics& m) {
        if (!text)
            return 0;
        const int n = static_cast<int>(std::strlen(text));
        if (n <= 0)
            return 0;
        const int sc = std::max(kOverlayMinScale, m.bodyScale);
        return n * m.glyphAdvance * sc - sc;
    }

    // Uppercase + truncate to maxPx (append "..." when clipped). outCap includes NUL.
    static void fitText(const char* text, const OverlayLayoutMetrics& m, int maxPx, char* out,
                        size_t outCap) {
        if (!out || outCap == 0)
            return;
        out[0] = '\0';
        if (!text || maxPx <= 0)
            return;
        char upper[64];
        size_t n = 0;
        for (const char* p = text; *p && n + 1 < sizeof(upper); ++p) {
            char c = *p;
            if (c >= 'a' && c <= 'z')
                c = static_cast<char>(c - 'a' + 'A');
            // Keep printable ASCII; drop others as space so width stays stable.
            if (c < 32 || c > 126)
                c = ' ';
            upper[n++] = c;
        }
        upper[n] = '\0';
        if (n == 0)
            return;
        if (textWidth(upper, m) <= maxPx) {
            std::snprintf(out, outCap, "%s", upper);
            return;
        }
        const char* ell = "...";
        const int ellW = textWidth(ell, m);
        if (ellW > maxPx) {
            out[0] = '\0';
            return;
        }
        // Binary-ish shrink: drop chars until upper[0..k) + "..." fits.
        while (n > 0) {
            --n;
            upper[n] = '\0';
            char trial[68];
            std::snprintf(trial, sizeof(trial), "%s%s", upper, ell);
            if (textWidth(trial, m) <= maxPx) {
                std::snprintf(out, outCap, "%s", trial);
                return;
            }
        }
        std::snprintf(out, outCap, "%s", ell);
    }

    // 12×16 bitmaps: each row is 12 bits in the high 12 of a uint16_t (MSB = left).
    // Hand-authored geometric glyphs (CC0-1.0).
    static const uint16_t* glyph12(char ch) {
        static constexpr uint16_t space[16] = {};
        static constexpr uint16_t d0[16] = {
            0x0000, 0x1F80, 0x30C0, 0x6060, 0x6060, 0x6060, 0x6060, 0x6060,
            0x6060, 0x6060, 0x6060, 0x6060, 0x30C0, 0x1F80, 0x0000, 0x0000};
        static constexpr uint16_t d1[16] = {
            0x0000, 0x0C00, 0x1C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00,
            0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x3F00, 0x0000, 0x0000};
        static constexpr uint16_t d2[16] = {
            0x0000, 0x1F00, 0x30C0, 0x0060, 0x0060, 0x00C0, 0x0180, 0x0300,
            0x0600, 0x0C00, 0x1800, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000};
        static constexpr uint16_t d3[16] = {
            0x0000, 0x1F00, 0x30C0, 0x0060, 0x0060, 0x00C0, 0x0F00, 0x00C0,
            0x0060, 0x0060, 0x0060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t d4[16] = {
            0x0000, 0x0180, 0x0380, 0x0780, 0x0D80, 0x1980, 0x3180, 0x3FC0,
            0x0180, 0x0180, 0x0180, 0x0180, 0x0180, 0x0180, 0x0000, 0x0000};
        static constexpr uint16_t d5[16] = {
            0x0000, 0x3FC0, 0x3000, 0x3000, 0x3000, 0x3F00, 0x30C0, 0x0060,
            0x0060, 0x0060, 0x0060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t d6[16] = {
            0x0000, 0x0F00, 0x1800, 0x3000, 0x3000, 0x3F00, 0x30C0, 0x3060,
            0x3060, 0x3060, 0x3060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t d7[16] = {
            0x0000, 0x3FC0, 0x0060, 0x00C0, 0x00C0, 0x0180, 0x0180, 0x0300,
            0x0300, 0x0600, 0x0600, 0x0600, 0x0600, 0x0600, 0x0000, 0x0000};
        static constexpr uint16_t d8[16] = {
            0x0000, 0x1F00, 0x30C0, 0x3060, 0x3060, 0x30C0, 0x1F00, 0x30C0,
            0x3060, 0x3060, 0x3060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t d9[16] = {
            0x0000, 0x1F00, 0x30C0, 0x3060, 0x3060, 0x3060, 0x30C0, 0x1F60,
            0x0060, 0x0060, 0x0060, 0x00C0, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t colon[16] = {
            0x0000, 0x0000, 0x0C00, 0x0C00, 0x0000, 0x0000, 0x0000, 0x0000,
            0x0000, 0x0C00, 0x0C00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t lt[16] = {
            0x0000, 0x0060, 0x00C0, 0x0180, 0x0300, 0x0600, 0x0C00, 0x1800,
            0x0C00, 0x0600, 0x0300, 0x0180, 0x00C0, 0x0060, 0x0000, 0x0000};
        static constexpr uint16_t gt[16] = {
            0x0000, 0x1800, 0x0C00, 0x0600, 0x0300, 0x0180, 0x00C0, 0x0060,
            0x00C0, 0x0180, 0x0300, 0x0600, 0x0C00, 0x1800, 0x0000, 0x0000};
        static constexpr uint16_t minus[16] = {
            0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x3FC0, 0x3FC0,
            0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t slash[16] = {
            0x0000, 0x0060, 0x0060, 0x00C0, 0x00C0, 0x0180, 0x0180, 0x0300,
            0x0300, 0x0600, 0x0600, 0x0C00, 0x0C00, 0x1800, 0x0000, 0x0000};
        // Letters used by state labels / notices (subset).
        static constexpr uint16_t A[16] = {
            0x0000, 0x0F00, 0x1980, 0x30C0, 0x30C0, 0x30C0, 0x3FC0, 0x30C0,
            0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x0000, 0x0000};
        static constexpr uint16_t D[16] = {
            0x0000, 0x3E00, 0x3180, 0x30C0, 0x3060, 0x3060, 0x3060, 0x3060,
            0x3060, 0x3060, 0x30C0, 0x3180, 0x3E00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t E[16] = {
            0x0000, 0x3FC0, 0x3000, 0x3000, 0x3000, 0x3000, 0x3F00, 0x3000,
            0x3000, 0x3000, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t G[16] = {
            0x0000, 0x1F00, 0x30C0, 0x3000, 0x3000, 0x3000, 0x33C0, 0x3060,
            0x3060, 0x3060, 0x3060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t I[16] = {
            0x0000, 0x3F00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00,
            0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x3F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t L[16] = {
            0x0000, 0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x3000,
            0x3000, 0x3000, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t N[16] = {
            0x0000, 0x30C0, 0x38C0, 0x3CC0, 0x36C0, 0x36C0, 0x33C0, 0x31C0,
            0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t O[16] = {
            0x0000, 0x1F00, 0x30C0, 0x6060, 0x6060, 0x6060, 0x6060, 0x6060,
            0x6060, 0x6060, 0x6060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t P[16] = {
            0x0000, 0x3F00, 0x30C0, 0x3060, 0x3060, 0x30C0, 0x3F00, 0x3000,
            0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t S[16] = {
            0x0000, 0x1F00, 0x30C0, 0x3000, 0x3000, 0x1F00, 0x00C0, 0x0060,
            0x0060, 0x0060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t T[16] = {
            0x0000, 0x3FC0, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00,
            0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t U[16] = {
            0x0000, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0,
            0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t Y[16] = {
            0x0000, 0x30C0, 0x30C0, 0x30C0, 0x1980, 0x0F00, 0x0600, 0x0600,
            0x0600, 0x0600, 0x0600, 0x0600, 0x0600, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t R[16] = {
            0x0000, 0x3F00, 0x30C0, 0x3060, 0x3060, 0x30C0, 0x3F00, 0x3300,
            0x3180, 0x30C0, 0x3060, 0x3060, 0x3060, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t C[16] = {
            0x0000, 0x1F00, 0x30C0, 0x3000, 0x3000, 0x3000, 0x3000, 0x3000,
            0x3000, 0x3000, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t M[16] = {
            0x0000, 0x60C0, 0x71C0, 0x7BC0, 0x6EC0, 0x64C0, 0x60C0, 0x60C0,
            0x60C0, 0x60C0, 0x60C0, 0x60C0, 0x60C0, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t W[16] = {
            0x0000, 0x60C0, 0x60C0, 0x60C0, 0x60C0, 0x60C0, 0x60C0, 0x64C0,
            0x6EC0, 0x7BC0, 0x71C0, 0x60C0, 0x60C0, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t H[16] = {
            0x0000, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x3FC0, 0x30C0,
            0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t K[16] = {
            0x0000, 0x3060, 0x30C0, 0x3180, 0x3300, 0x3600, 0x3C00, 0x3C00,
            0x3600, 0x3300, 0x3180, 0x30C0, 0x3060, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t B[16] = {
            0x0000, 0x3F00, 0x30C0, 0x3060, 0x3060, 0x30C0, 0x3F00, 0x30C0,
            0x3060, 0x3060, 0x3060, 0x30C0, 0x3F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t V[16] = {
            0x0000, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0,
            0x1980, 0x1980, 0x0F00, 0x0F00, 0x0600, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t F[16] = {
            0x0000, 0x3FC0, 0x3000, 0x3000, 0x3000, 0x3000, 0x3F00, 0x3000,
            0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t J[16] = {
            0x0000, 0x0FC0, 0x0180, 0x0180, 0x0180, 0x0180, 0x0180, 0x0180,
            0x0180, 0x3180, 0x3180, 0x3180, 0x1F00, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t Q[16] = {
            0x0000, 0x1F00, 0x30C0, 0x6060, 0x6060, 0x6060, 0x6060, 0x6060,
            0x66C0, 0x63C0, 0x6180, 0x30C0, 0x1F60, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t X[16] = {
            0x0000, 0x30C0, 0x30C0, 0x1980, 0x0F00, 0x0600, 0x0600, 0x0F00,
            0x1980, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x0000, 0x0000, 0x0000};
        static constexpr uint16_t Z[16] = {
            0x0000, 0x3FC0, 0x0060, 0x00C0, 0x0180, 0x0300, 0x0600, 0x0C00,
            0x1800, 0x3000, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000, 0x0000};
        if (ch >= 'a' && ch <= 'z')
            ch = static_cast<char>(ch - 'a' + 'A');
        switch (ch) {
        case '0': return d0; case '1': return d1; case '2': return d2; case '3': return d3;
        case '4': return d4; case '5': return d5; case '6': return d6; case '7': return d7;
        case '8': return d8; case '9': return d9; case ':': return colon; case '<': return lt;
        case '>': return gt; case '-': return minus; case '/': return slash;
        case 'A': return A; case 'B': return B; case 'C': return C; case 'D': return D;
        case 'E': return E; case 'F': return F; case 'G': return G; case 'H': return H;
        case 'I': return I; case 'J': return J; case 'K': return K; case 'L': return L;
        case 'M': return M; case 'N': return N; case 'O': return O; case 'P': return P;
        case 'Q': return Q; case 'R': return R; case 'S': return S; case 'T': return T;
        case 'U': return U; case 'V': return V; case 'W': return W; case 'X': return X;
        case 'Y': return Y; case 'Z': return Z;
        default: return space;
        }
    }

    template <typename Target>
    static void drawText(Target& t, int x, int y, const char* text, const OverlayLayoutMetrics& m,
                         Color c, int alpha) {
        if (!text)
            return;
        // Enforce vertical scale >= 2 so each glyph row survives even-row cull.
        const int sc = std::max(kOverlayMinScale, m.bodyScale);
        // Snap origin to even content row — surviving phase is deterministic.
        y &= ~1;
        for (const char* p = text; *p; ++p) {
            if (m.fontId == OverlayFontId::Hires24x32) {
                const uint32_t* g = overlay_font_24x32::glyph(*p);
                for (int row = 0; row < m.glyphH; ++row) {
                    const uint32_t bits = g[row];
                    for (int col = 0; col < m.glyphW; ++col) {
                        if ((bits & (1u << (31 - col))) == 0)
                            continue;
                        fillRect(t, x + col * sc, y + row * sc, sc, sc, c, alpha);
                    }
                }
            } else if (m.fontId == OverlayFontId::Large12x16) {
                const uint16_t* g = glyph12(*p);
                for (int row = 0; row < m.glyphH; ++row) {
                    const uint16_t bits = g[row];
                    for (int col = 0; col < m.glyphW; ++col) {
                        if ((bits & (1u << (15 - col))) == 0)
                            continue;
                        fillRect(t, x + col * sc, y + row * sc, sc, sc, c, alpha);
                    }
                }
            } else {
                const uint8_t* g = glyph(*p);
                for (int row = 0; row < m.glyphH; ++row) {
                    const uint8_t bits = g[row];
                    for (int col = 0; col < m.glyphW; ++col) {
                        if ((bits & (1u << (7 - col))) == 0)
                            continue;
                        fillRect(t, x + col * sc, y + row * sc, sc, sc, c, alpha);
                    }
                }
            }
            x += m.glyphAdvance * sc;
        }
    }

    static void formatTime(int64_t ms, char (&out)[32]) {
        int64_t sec = ms / 1000;
        const int64_t hh = sec / 3600;
        sec %= 3600;
        const int64_t mm = sec / 60;
        const int64_t ss = sec % 60;
        if (hh > 0)
            std::snprintf(out, 32, "%lld:%02lld:%02lld", static_cast<long long>(hh),
                          static_cast<long long>(mm), static_cast<long long>(ss));
        else
            std::snprintf(out, 32, "%lld:%02lld", static_cast<long long>(mm),
                          static_cast<long long>(ss));
    }

    template <typename Target>
    static void drawIcon(Target& t, PlaybackOverlayState state, int cx, int cy, int alpha,
                         int iconScale) {
        constexpr Color amber{255, 178, 32};
        const int s = std::max(kOverlayMinScale, iconScale);
        if (state == PlaybackOverlayState::Playing) {
            // Filled play triangle (base 14×s, height 16×s) — not a 5×7 stair.
            for (int row = 0; row < 16 * s; ++row) {
                const int half = (row * 7 * s) / (16 * s);
                const int x0 = cx - 6 * s;
                fillRect(t, x0, cy - 8 * s + row, half * 2 + s, s, amber, alpha);
            }
        } else if (state == PlaybackOverlayState::Paused) {
            // Two bars, 5×16 cells with 4px gap at s=1.
            fillRect(t, cx - 8 * s, cy - 8 * s, 5 * s, 16 * s, amber, alpha);
            fillRect(t, cx + 3 * s, cy - 8 * s, 5 * s, 16 * s, amber, alpha);
        } else {
            // Stop square.
            fillRect(t, cx - 7 * s, cy - 7 * s, 14 * s, 14 * s, amber, alpha);
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
    static void render(Target& t, const Snapshot& s, int w, int h, int64_t nowMs,
                       bool outputRaster = false) {
        const int alpha = alphaFor(s, nowMs);
        const OverlayLayoutMetrics m = OverlayLayoutMetrics::resolve(w, h, outputRaster);
        constexpr Color black{0, 0, 0};
        constexpr Color panelEdge{70, 74, 82};
        constexpr Color white{235, 238, 244};
        constexpr Color muted{130, 138, 150};
        constexpr Color amber{255, 178, 32};

        if (alpha > 0) {
            const OverlayRect p = panelBounds(w, h, outputRaster);
            // Opaque dark-grey chrome (not pure black@170). Translucent black
            // left the empty center (right of state label, above scrubber) as a
            // solid black rectangle over video — silicon Test B residual hole
            // at ~x247-397 y360-404 on 624x480. Opaque panelBg makes that band
            // intentional chrome grey independent of underlying luma.
            constexpr Color panelBg{42, 46, 54};
            fillRect(t, p.x, p.y, p.w, p.h, panelBg, alpha);
            strokeRect(t, p.x, p.y, p.w, p.h, panelEdge, (200 * alpha) / 255);

            const int iconXFinal = p.x + 18;
            // Even y-origins: present_core drops odd store rows.
            const int labelY = (p.y + m.labelTop) & ~1;
            const int iconCy = (p.y + m.iconCy) & ~1;
            const int iconSc = std::max(kOverlayMinScale, m.iconScale);
            drawIcon(t, s.state, iconXFinal, iconCy, alpha, iconSc);
            const int stateX = iconXFinal + 14 + 8 * iconSc;
            const char* label = stateLabel(s.state);
            drawText(t, stateX, labelY, label, m, white, alpha);

            // Title fills the former empty black band (right of state label).
            if (s.titleText[0] != '\0') {
                const int gap = std::max(10, 6 * m.bodyScale);
                const int titleX = stateX + textWidth(label, m) + gap;
                const int titleMaxR = p.x + p.w - 14;
                if (titleX + m.glyphAdvance * m.bodyScale < titleMaxR) {
                    char fitted[64];
                    fitText(s.titleText, m, titleMaxR - titleX, fitted, sizeof(fitted));
                    if (fitted[0] != '\0')
                        drawText(t, titleX, labelY, fitted, m, muted, alpha);
                }
            }

            char elapsed[32];
            char total[32];
            formatTime(s.positionMs, elapsed);
            formatTime(s.durationMs, total);
            const int timeY = (p.y + m.timeTop) & ~1;
            drawText(t, p.x + 14, timeY, elapsed, m, white, alpha);
            const int totalW = textWidth(total, m);
            drawText(t, p.x + p.w - 14 - totalW, timeY, total, m, muted, alpha);

            const int barX = p.x + 14;
            const int barH = m.barH;
            const int barBottomPad = m.barBottomPad;
            const int barY = p.y + p.h - barBottomPad;
            const int barW = p.w - 28;
            fillRect(t, barX, barY, barW, barH, Color{58, 63, 72}, (220 * alpha) / 255);
            int fillW = 0;
            if (s.durationMs > 0)
                fillW = static_cast<int>((static_cast<long long>(barW) *
                                          std::min(s.positionMs, s.durationMs)) /
                                         s.durationMs);
            fillW = std::max(0, std::min(barW, fillW));
            if (fillW > 0)
                fillRect(t, barX, barY, fillW, barH, amber, alpha);
            const int knobX = barX + fillW;
            const int knobW = std::max(5, m.barH);
            const int knobH = std::max(10, barH + 4);
            fillRect(t, knobX - knobW / 2, barY - (knobH - barH) / 2, knobW, knobH, white, alpha);
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
            const int tw = textWidth(text, m);
            const int boxW = std::min(w - 16, std::max(76, tw + 24));
            const int boxX = (w - boxW) / 2;
            const int boxH = m.skipBoxH;
            const int boxY = std::max(8, h / 2 - boxH - 2);
            fillRect(t, boxX, boxY, boxW, boxH, black, (190 * skipAlpha) / 255);
            strokeRect(t, boxX, boxY, boxW, boxH, amber, skipAlpha);
            const int textY = (boxY + std::max(4, (boxH - m.textCellH()) / 2)) & ~1;
            drawText(t, boxX + (boxW - tw) / 2, textY, text, m, white, skipAlpha);
        }

        const int noticeAlpha = noticeAlphaFor(s, nowMs);
        if (noticeAlpha > 0 && s.noticeText[0] != '\0') {
            const int tw = textWidth(s.noticeText, m);
            const int boxW = std::min(w - 16, std::max(76, tw + 24));
            const int boxX = (w - boxW) / 2;
            const int boxH = m.noticeBoxH;
            const int boxY = std::max(8, h / 5);
            fillRect(t, boxX, boxY, boxW, boxH, black, (200 * noticeAlpha) / 255);
            strokeRect(t, boxX, boxY, boxW, boxH, amber, noticeAlpha);
            const int textY = (boxY + std::max(4, (boxH - m.textCellH()) / 2)) & ~1;
            drawText(t, boxX + (boxW - tw) / 2, textY, s.noticeText, m, white, noticeAlpha);
        }
    }

    mutable std::mutex mu_;
    std::atomic<bool> outputRasterLayout_{false};
    PlaybackOverlayState state_ = PlaybackOverlayState::Stopped;
    int64_t positionMs_ = 0;
    int64_t durationMs_ = 0;
    int64_t shownAtMs_ = -kVisibleMs;
    int64_t skipAtMs_ = -kSkipVisibleMs;
    int64_t skipDeltaMs_ = 0;
    int64_t noticeAtMs_ = -kNoticeVisibleMs;
    char noticeText_[32]{};
    char titleText_[64]{};
};

} // namespace misterplex
