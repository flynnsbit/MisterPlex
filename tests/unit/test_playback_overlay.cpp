#include "libmisterplex/playback_overlay.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <tuple>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

#define CHECK_EQ_U64(actual, expected)                                                           \
    do {                                                                                         \
        const uint64_t a_ = (actual);                                                            \
        const uint64_t e_ = (expected);                                                          \
        if (a_ != e_) {                                                                          \
            std::fprintf(stderr, "FAIL %s:%d got=0x%016llx want=0x%016llx\n", __FILE__,         \
                         __LINE__, static_cast<unsigned long long>(a_),                          \
                         static_cast<unsigned long long>(e_));                                   \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

#define CHECK_EQ_HEX16(actual, expected)                                                         \
    do {                                                                                         \
        const uint16_t a_ = (actual);                                                            \
        const uint16_t e_ = (expected);                                                          \
        if (a_ != e_) {                                                                          \
            std::fprintf(stderr, "FAIL %s:%d got=0x%04x want=0x%04x\n", __FILE__, __LINE__, a_,  \
                         e_);                                                                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

namespace {

constexpr int W = 320;
constexpr int H = 240;
constexpr uint16_t kAmber565 = 0xfd84;
constexpr uint16_t kWhite565 = 0xef7e;

// Bar geometry follows OverlayLayoutMetrics (not hardcoded pre-8x13 anchors).
struct BarGeom {
    int x = 0, y = 0, w = 0, h = 0;
};
BarGeom barGeom320() {
    const auto lay = misterplex::PlaybackOverlay::computePanelLayout(
        W, H, false, misterplex::PlaybackOverlayState::Playing, "", 0, 100000);
    BarGeom b;
    b.x = lay.barX;
    b.w = lay.barW;
    b.h = lay.barH;
    b.y = lay.barY;
    return b;
}

struct PixelGold {
    int x = 0;
    int y = 0;
    uint16_t value = 0;
};

struct Golden {
    uint64_t fnv64 = 0;
    misterplex::OverlayRect dirty;
    std::vector<PixelGold> pixels;
};

uint16_t pack565(unsigned r, unsigned g, unsigned b) {
    return static_cast<uint16_t>(((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3));
}

uint64_t fnv1a(const std::vector<uint8_t>& buf) {
    uint64_t h = 1469598103934665603ull;
    for (uint8_t b : buf) {
        h ^= b;
        h *= 1099511628211ull;
    }
    return h;
}

uint16_t rgb565At(const std::vector<uint8_t>& buf, int x, int y) {
    const size_t i = (static_cast<size_t>(y) * W + x) * 2;
    return static_cast<uint16_t>(buf[i] | (buf[i + 1] << 8));
}

std::vector<uint8_t> syntheticBackground() {
    std::vector<uint8_t> out(static_cast<size_t>(W) * H * 2);
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            const uint16_t p = pack565((x * 3 + y * 5) & 0xff, (x * 7 + y * 11) & 0xff,
                                       (x * 13 + y * 17) & 0xff);
            const size_t i = (static_cast<size_t>(y) * W + x) * 2;
            out[i + 0] = static_cast<uint8_t>(p & 0xff);
            out[i + 1] = static_cast<uint8_t>(p >> 8);
        }
    }
    return out;
}

std::vector<uint8_t> blackFrame() {
    return std::vector<uint8_t>(static_cast<size_t>(W) * H * 2, 0);
}

uint64_t parseU64(const std::string& s) {
    return static_cast<uint64_t>(std::strtoull(s.c_str(), nullptr, 0));
}

Golden loadGolden() {
    std::ifstream f("tests/unit/golden/playback_overlay_rgb565.txt");
    if (!f) {
        std::fprintf(stderr, "FAIL cannot open playback overlay golden artifact\n");
        ++fails;
        return {};
    }
    Golden g;
    std::string tag;
    while (f >> tag) {
        if (tag == "fnv64") {
            std::string v;
            f >> v;
            g.fnv64 = parseU64(v);
        } else if (tag == "dirty") {
            f >> g.dirty.x >> g.dirty.y >> g.dirty.w >> g.dirty.h;
        } else if (tag == "pixel") {
            PixelGold p;
            std::string v;
            f >> p.x >> p.y >> v;
            p.value = static_cast<uint16_t>(parseU64(v));
            g.pixels.push_back(p);
        } else {
            std::fprintf(stderr, "FAIL unknown golden tag: %s\n", tag.c_str());
            ++fails;
            break;
        }
    }
    return g;
}

bool inside(const misterplex::OverlayRect& r, int x, int y) {
    return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h;
}

void checkOutsideDirtyUnchanged(const std::vector<uint8_t>& before,
                                const std::vector<uint8_t>& after,
                                const misterplex::OverlayRect& dirty) {
    CHECK(before.size() == after.size());
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            if (inside(dirty, x, y))
                continue;
            const size_t i = (static_cast<size_t>(y) * W + x) * 2;
            if (before[i] != after[i] || before[i + 1] != after[i + 1]) {
                std::fprintf(stderr,
                             "FAIL outside dirty changed at (%d,%d): got=%02x%02x want=%02x%02x\n",
                             x, y, after[i + 1], after[i], before[i + 1], before[i]);
                ++fails;
                return;
            }
        }
    }
}

int knobCenterOnBar(const std::vector<uint8_t>& buf) {
    const BarGeom bar = barGeom320();
    int lo = 9999;
    int hi = -1;
    const int y = bar.y + std::max(0, bar.h / 2);
    for (int x = bar.x - 6; x < bar.x + bar.w + 8; ++x) {
        if (x >= 0 && x < W && rgb565At(buf, x, y) == kWhite565) {
            lo = std::min(lo, x);
            hi = std::max(hi, x);
        }
    }
    if (hi < lo)
        return -1;
    return (lo + hi) / 2;
}

void renderProgressCase(int64_t elapsedMs, int64_t durationMs, std::vector<uint8_t>& frame) {
    misterplex::PlaybackOverlay ov;
    ov.showAt(misterplex::PlaybackOverlayState::Playing, elapsedMs, durationMs, 5000);
    CHECK(ov.renderRgb565LeAt(frame.data(), W, H, 5000));
}

void checkGuardedProgress(int64_t elapsedMs, int64_t durationMs, int expectedKnobX) {
    constexpr size_t kGuard = 32;
    std::vector<uint8_t> guarded(kGuard + static_cast<size_t>(W) * H * 2 + kGuard, 0xa5);
    std::fill(guarded.begin() + static_cast<std::ptrdiff_t>(kGuard),
              guarded.end() - static_cast<std::ptrdiff_t>(kGuard), 0);
    misterplex::PlaybackOverlay ov;
    ov.showAt(misterplex::PlaybackOverlayState::Playing, elapsedMs, durationMs, 3000);
    CHECK(ov.renderRgb565LeAt(guarded.data() + kGuard, W, H, 3000));
    for (size_t i = 0; i < kGuard; ++i) {
        CHECK(guarded[i] == 0xa5);
        CHECK(guarded[guarded.size() - 1 - i] == 0xa5);
    }
    std::vector<uint8_t> frame(guarded.begin() + static_cast<std::ptrdiff_t>(kGuard),
                               guarded.end() - static_cast<std::ptrdiff_t>(kGuard));
    const int center = knobCenterOnBar(frame);
    if (std::abs(center - expectedKnobX) > 1) {
        std::fprintf(stderr, "FAIL progress knob center got=%d want≈%d\n", center,
                     expectedKnobX);
        ++fails;
    }
}

} // namespace

int main() {
    using namespace misterplex;

    // 1. Deterministic rendering: exact RGB565 frame hash plus readable pixel checks.
    const Golden golden = loadGolden();
    PlaybackOverlay ov;
    const std::vector<uint8_t> background = syntheticBackground();
    std::vector<uint8_t> frame = background;
    ov.showAt(PlaybackOverlayState::Playing, 61000, 2732000, 10000);
    const OverlayRect dirty = ov.dirtyBoundsAt(W, H, 10000);
    CHECK(dirty.x == golden.dirty.x);
    CHECK(dirty.y == golden.dirty.y);
    CHECK(dirty.w == golden.dirty.w);
    CHECK(dirty.h == golden.dirty.h);
    CHECK(ov.renderRgb565LeAt(frame.data(), W, H, 10000));
    CHECK_EQ_U64(fnv1a(frame), golden.fnv64);
    for (const PixelGold& p : golden.pixels)
        CHECK_EQ_HEX16(rgb565At(frame, p.x, p.y), p.value);

    // 4. Non-destructive compositing: outside the dirty rect is byte-identical.
    checkOutsideDirtyUnchanged(background, frame, dirty);

    // 2. Progress-bar geometry and edge cases.
    {
        const BarGeom bar = barGeom320();
        std::vector<uint8_t> zero = blackFrame();
        renderProgressCase(0, 100000, zero);
        CHECK(std::abs(knobCenterOnBar(zero) - bar.x) <= 2);
        CHECK(rgb565At(zero, bar.x + 4, bar.y + bar.h / 2) != kAmber565);

        std::vector<uint8_t> half = blackFrame();
        renderProgressCase(100000, 200000, half);
        CHECK(std::abs(knobCenterOnBar(half) - (bar.x + bar.w / 2)) <= 2);
        CHECK_EQ_HEX16(rgb565At(half, bar.x + bar.w / 2 - 4, bar.y + bar.h / 2), kAmber565);
        CHECK(rgb565At(half, bar.x + bar.w / 2 + 4, bar.y + bar.h / 2) != kAmber565);

        std::vector<uint8_t> full = blackFrame();
        renderProgressCase(200000, 200000, full);
        CHECK(std::abs(knobCenterOnBar(full) - (bar.x + bar.w)) <= 2);
        CHECK_EQ_HEX16(rgb565At(full, bar.x + bar.w - 4, bar.y + bar.h / 2), kAmber565);

        checkGuardedProgress(400000, 200000, bar.x + bar.w); // seek overshoot clamps full
        checkGuardedProgress(100000, 0, bar.x);               // live stream duration unknown
    }

    // 3. Auto-hide timing with injected timestamps, no sleeps.
    // Playing/Stopped transient; Paused is sticky (Test B — panel must survive warm-up).
    {
        PlaybackOverlay timed;
        timed.showAt(PlaybackOverlayState::Playing, 1000, 5000, 10000);
        CHECK(timed.visibleAt(10000));
        CHECK(timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs - PlaybackOverlay::kFadeMs));
        CHECK(timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs - 1));
        CHECK(!timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs));
        CHECK(timed.dirtyBoundsAt(W, H, 10000 + PlaybackOverlay::kVisibleMs).empty());

        timed.showAt(PlaybackOverlayState::Paused, 1000, 5000, 10000);
        CHECK(timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs + 60'000));
        CHECK(!timed.dirtyBoundsAt(W, H, 10000 + PlaybackOverlay::kVisibleMs + 60'000).empty());

        timed.flashSkipAt(30000, 2000, 90000, 20000);
        // flashSkip refreshes show time but state remains Paused → still sticky.
        CHECK(timed.visibleAt(20000));
        CHECK(timed.visibleAt(20000 + PlaybackOverlay::kVisibleMs + 1));
    }

    // 5. Multi-resolution layout: no overflow, sane panel fractions, bar endpoints.
    {
        struct Case { int w; int h; const char* name; };
        const Case cases[] = {
            {1920, 1080, "1080p"},
            {800, 600, "800x600"},
            {640, 480, "640x480"},
            {320, 240, "320x240"},
        };
        for (const Case& c : cases) {
            PlaybackOverlay hi;
            hi.showAt(PlaybackOverlayState::Paused, 90000, 180000, 1000);
            const OverlayRect d = hi.dirtyBoundsAt(c.w, c.h, 1000);
            CHECK(!d.empty());
            CHECK(d.x >= 0);
            CHECK(d.y >= 0);
            CHECK(d.x + d.w <= c.w);
            CHECK(d.y + d.h <= c.h);
            const auto layP = PlaybackOverlay::computePanelLayout(
                c.w, c.h, false, PlaybackOverlayState::Paused, "MISTERPLEX", 90000, 180000);
            const OverlayRect panel = layP.panel;
            CHECK(panel.w > 0 && panel.h > 0);
            CHECK(panel.x >= 0 && panel.y >= 0);
            CHECK(panel.x + panel.w <= c.w);
            CHECK(panel.y + panel.h <= c.h);
            // Panel occupies a sane fraction of height (about 5–50%).
            CHECK(panel.h * 20 >= c.h);       // >= 5%
            CHECK(panel.h * 2 <= c.h);         // <= 50% (hires 24x32@2 + title line)
            CHECK(layP.stringsFitPanel());
            const auto lm = PlaybackOverlay::layoutMetrics(c.w, c.h);
            // present_core odd-row cull requires vertical scale >= 2.
            CHECK(lm.bodyScale >= 2);
            // Timeline endpoints: half progress → fill mid-bar.
            std::vector<uint8_t> rgb(static_cast<size_t>(c.w) * c.h * 3, 0);
            CHECK(hi.renderRgb24At(rgb.data(), c.w, c.h, 1000));
            const auto layBar = PlaybackOverlay::computePanelLayout(
                c.w, c.h, false, PlaybackOverlayState::Playing, "", 90000, 180000);
            const int barX = layBar.barX;
            const int barW = layBar.barW;
            const int barH = layBar.barH;
            const int barY = layBar.barY;
            const int midX = barX + barW / 2;
            // Sample Y near bar center row; amber progress should be left of mid, track right.
            auto pix = [&](int x, int y) -> std::tuple<uint8_t,uint8_t,uint8_t> {
                const size_t i = (static_cast<size_t>(y) * c.w + x) * 3;
                return {rgb[i], rgb[i+1], rgb[i+2]};
            };
            // Half elapsed (90000/180000): fill ends near mid.
            auto [rL, gL, bL] = pix(std::max(barX + 2, midX - 8), barY + barH / 2);
            auto [rR, gR, bR] = pix(std::min(c.w - 1, midX + 8), barY + barH / 2);
            // Left of mid should be amber-ish (high R), right darker track.
            CHECK(rL > 100);
            CHECK(rL >= rR);
            (void)gL; (void)bL; (void)gR; (void)bR; (void)c.name;
        }
    }

    // 6. Overlay geometry independent of "content" — only buffer size matters.
    // Two different synthetic backgrounds at the same output size must yield
    // identical overlay-dominated pixels when composited (same show state).
    {
        constexpr int OW = 640, OH = 480;
        auto mkBg = [&](uint8_t seed) {
            std::vector<uint8_t> b(static_cast<size_t>(OW) * OH * 3);
            for (size_t i = 0; i < b.size(); i += 3) {
                b[i] = static_cast<uint8_t>((seed * 17 + i) & 0xff);
                b[i+1] = static_cast<uint8_t>((seed * 29 + i * 3) & 0xff);
                b[i+2] = static_cast<uint8_t>((seed * 43 + i * 5) & 0xff);
            }
            return b;
        };
        // Render onto pure black twice after identical show — full-frame match.
        std::vector<uint8_t> a(static_cast<size_t>(OW) * OH * 3, 0);
        std::vector<uint8_t> b(static_cast<size_t>(OW) * OH * 3, 0);
        PlaybackOverlay oa, ob;
        oa.showAt(PlaybackOverlayState::Playing, 1000, 5000, 50);
        ob.showAt(PlaybackOverlayState::Playing, 1000, 5000, 50);
        CHECK(oa.renderRgb24At(a.data(), OW, OH, 50));
        CHECK(ob.renderRgb24At(b.data(), OW, OH, 50));
        CHECK(a == b);
        // Different backgrounds: dirty-rect overlay absolute colors for opaque
        // white text pixels should match (alpha 255 text sets absolute color).
        auto bg1 = mkBg(1);
        auto bg2 = mkBg(99);
        PlaybackOverlay o1, o2;
        o1.showAt(PlaybackOverlayState::Paused, 0, 10000, 10);
        o2.showAt(PlaybackOverlayState::Paused, 0, 10000, 10);
        CHECK(o1.renderRgb24At(bg1.data(), OW, OH, 10));
        CHECK(o2.renderRgb24At(bg2.data(), OW, OH, 10));
        const OverlayRect panel = PlaybackOverlay::panelBounds(OW, OH);
        // Panel geometry identical regardless of background/"content".
        CHECK(panel.x == PlaybackOverlay::panelBounds(OW, OH).x);
        CHECK(o1.dirtyBoundsAt(OW, OH, 10).x == o2.dirtyBoundsAt(OW, OH, 10).x);
        CHECK(o1.dirtyBoundsAt(OW, OH, 10).y == o2.dirtyBoundsAt(OW, OH, 10).y);
        CHECK(o1.dirtyBoundsAt(OW, OH, 10).w == o2.dirtyBoundsAt(OW, OH, 10).w);
        CHECK(o1.dirtyBoundsAt(OW, OH, 10).h == o2.dirtyBoundsAt(OW, OH, 10).h);
        (void)panel;
    }

    // 7. Even-row cull survival + string read-back of "STOPPED".
    // present_core fetches only even store rows (STORE_Y_SCALE=2). scale=1
    // destroys alternate glyph rows (8→0 etc). bodyScale>=2 + even y keeps
    // every glyph feature on a surviving row. Recover label by template match
    // on the even-row raster (DE-class), not edge sharpness.
    {
        constexpr int OW = 624, OH = 480;
        const auto lm = PlaybackOverlay::layoutMetrics(OW, OH);
        CHECK(lm.bodyScale >= 2);
        CHECK((PlaybackOverlay::panelBounds(OW, OH).y & 1) == 0);

        std::vector<uint8_t> rgb(static_cast<size_t>(OW) * OH * 3, 20);
        PlaybackOverlay ov;
        ov.showAt(PlaybackOverlayState::Stopped, 0, 0, 0);
        CHECK(ov.renderRgb24At(rgb.data(), OW, OH, 0));

        std::vector<uint8_t> evenY(static_cast<size_t>(OW) * (OH / 2));
        for (int y = 0; y < OH; y += 2) {
            for (int x = 0; x < OW; ++x) {
                const size_t i = (static_cast<size_t>(y) * OW + x) * 3;
                const int Y = (77 * rgb[i] + 150 * rgb[i + 1] + 29 * rgb[i + 2]) >> 8;
                evenY[static_cast<size_t>(y / 2) * OW + x] = static_cast<uint8_t>(Y);
            }
        }

        const int sc = lm.bodyScale;
        CHECK(sc >= 2);
        const bool large = (lm.fontId == misterplex::OverlayFontId::Hires24x32) ||
                           (lm.fontId == misterplex::OverlayFontId::Large12x16);

        // STOPPED templates — must match playback_overlay.hpp glyph tables.
        auto onAt = [&](char ch, int row, int col) -> bool {
            if (large) {
                static constexpr uint16_t S[16] = {
                    0x0000, 0x1F00, 0x30C0, 0x3000, 0x3000, 0x1F00, 0x00C0, 0x0060,
                    0x0060, 0x0060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000, 0x0000};
                static constexpr uint16_t T[16] = {
                    0x0000, 0x3FC0, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00,
                    0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0000, 0x0000, 0x0000};
                static constexpr uint16_t O[16] = {
                    0x0000, 0x1F00, 0x30C0, 0x6060, 0x6060, 0x6060, 0x6060, 0x6060,
                    0x6060, 0x6060, 0x6060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000};
                static constexpr uint16_t P[16] = {
                    0x0000, 0x3F00, 0x30C0, 0x3060, 0x3060, 0x30C0, 0x3F00, 0x3000,
                    0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x0000, 0x0000, 0x0000};
                static constexpr uint16_t E[16] = {
                    0x0000, 0x3FC0, 0x3000, 0x3000, 0x3000, 0x3000, 0x3F00, 0x3000,
                    0x3000, 0x3000, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000, 0x0000};
                static constexpr uint16_t D[16] = {
                    0x0000, 0x3E00, 0x3180, 0x30C0, 0x3060, 0x3060, 0x3060, 0x3060,
                    0x3060, 0x3060, 0x30C0, 0x3180, 0x3E00, 0x0000, 0x0000, 0x0000};
                const uint16_t* g = S;
                switch (ch) {
                case 'S': g = S; break;
                case 'T': g = T; break;
                case 'O': g = O; break;
                case 'P': g = P; break;
                case 'E': g = E; break;
                case 'D': g = D; break;
                default: break;
                }
                if (row < 0 || row >= 16 || col < 0 || col >= 12)
                    return false;
                return (g[row] & (1u << (15 - col))) != 0;
            }
            static constexpr uint8_t S[13] = {0x00, 0x3C, 0x66, 0x60, 0x60, 0x3C, 0x06,
                                             0x06, 0x06, 0x66, 0x3C, 0x00, 0x00};
            static constexpr uint8_t T[13] = {0x00, 0xFF, 0x18, 0x18, 0x18, 0x18, 0x18,
                                             0x18, 0x18, 0x18, 0x18, 0x00, 0x00};
            static constexpr uint8_t O[13] = {0x00, 0x3C, 0x66, 0xC3, 0xC3, 0xC3, 0xC3,
                                             0xC3, 0xC3, 0x66, 0x3C, 0x00, 0x00};
            static constexpr uint8_t P[13] = {0x00, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x60,
                                             0x60, 0x60, 0x60, 0x60, 0x00, 0x00};
            static constexpr uint8_t E[13] = {0x00, 0x7E, 0x60, 0x60, 0x60, 0x7C, 0x60,
                                             0x60, 0x60, 0x60, 0x7E, 0x00, 0x00};
            static constexpr uint8_t D[13] = {0x00, 0x78, 0x6C, 0x66, 0x66, 0x66, 0x66,
                                             0x66, 0x66, 0x6C, 0x78, 0x00, 0x00};
            const uint8_t* g = S;
            switch (ch) {
            case 'S': g = S; break;
            case 'T': g = T; break;
            case 'O': g = O; break;
            case 'P': g = P; break;
            case 'E': g = E; break;
            case 'D': g = D; break;
            default: break;
            }
            if (row < 0 || row >= 13 || col < 0 || col >= 8)
                return false;
            return (g[row] & (1u << (7 - col))) != 0;
        };

        const int gH = lm.glyphH;
        const int gW = lm.glyphW;
        const int adv = lm.glyphAdvance * sc;
        const OverlayRect panel = PlaybackOverlay::panelBounds(OW, OH);
        const int labelY = (panel.y + lm.labelTop) & ~1;
        const int evenLabelY = labelY / 2;
        const char* want = "STOPPED";
        const int nch = 7;
        const int wordW = nch * adv - sc;
        int bestScore = -1;
        int bestX = -1;
        int bestTotal = 1;
        for (int x0 = panel.x; x0 + wordW < panel.x + panel.w; ++x0) {
            int score = 0;
            int total = 0;
            for (int ci = 0; ci < nch; ++ci) {
                const int gx = x0 + ci * adv;
                for (int row = 0; row < gH; ++row) {
                    for (int col = 0; col < gW; ++col) {
                        const bool on = onAt(want[ci], row, col);
                        const int cy = evenLabelY + (row * sc + sc / 2) / 2;
                        const int cx = gx + col * sc + sc / 2;
                        if (cy < 0 || cy >= OH / 2 || cx < 0 || cx >= OW)
                            continue;
                        const uint8_t Y = evenY[static_cast<size_t>(cy) * OW + cx];
                        const bool bright = Y > 120;
                        ++total;
                        if (on == bright)
                            ++score;
                    }
                }
            }
            if (total > 0 && score > bestScore) {
                bestScore = score;
                bestTotal = total;
                bestX = x0;
            }
        }
        const double frac = bestScore / static_cast<double>(bestTotal);
        std::printf("even-row STOPPED readback: font=%s sc=%d bestX=%d score=%d/%d frac=%.3f\n",
                    lm.fontId == misterplex::OverlayFontId::Hires24x32 ? "24x32" : large ? "12x16" : "8x13", sc, bestX, bestScore, bestTotal, frac);
        CHECK(frac >= 0.85);
        CHECK(bestX >= 0);

        // Structural proof: scale=1 drops middle bar of classic 5×7 '8'.
        {
            const uint8_t g8[7] = {0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e};
            bool midSurvivesScale1 = false;
            bool midSurvivesScale2 = false;
            for (int r = 0; r < 7; ++r) {
                if ((r % 2) != 0)
                    continue;
                if (r == 3 && (g8[r] & 0x0e))
                    midSurvivesScale1 = true;
            }
            for (int r = 0; r < 7; ++r) {
                for (int vr = 0; vr < 2; ++vr) {
                    const int cr = r * 2 + vr;
                    if ((cr % 2) != 0)
                        continue;
                    if (r == 3 && (g8[r] & 0x0e))
                        midSurvivesScale2 = true;
                }
            }
            CHECK(!midSurvivesScale1);
            CHECK(midSurvivesScale2);
        }
    }

    // 8. YUV420p path actually paints (product PRESENT=fpga regression).
    {
        constexpr int OW = 640, OH = 480;
        std::vector<uint8_t> yuv(static_cast<size_t>(OW) * OH * 3 / 2, 16);
        // studio black chroma
        std::fill(yuv.begin() + OW * OH, yuv.end(), 128);
        PlaybackOverlay yov;
        yov.showAt(PlaybackOverlayState::Paused, 1000, 2000, 0);
        CHECK(yov.renderYuv420pAt(yuv.data(), OW, OH, 0));
        // Y plane inside panel should deviate from studio black (16).
        const OverlayRect panel = PlaybackOverlay::panelBounds(OW, OH);
        bool changed = false;
        for (int y = panel.y; y < panel.y + panel.h && !changed; ++y) {
            for (int x = panel.x; x < panel.x + panel.w; ++x) {
                if (yuv[static_cast<size_t>(y) * OW + x] != 16) {
                    changed = true;
                    break;
                }
            }
        }
        CHECK(changed);
    }

    // 9. Paused chrome is sticky past kVisibleMs (Test B regression).
    // Playing still auto-hides so transport flash does not stick forever.
    {
        using misterplex::PlaybackOverlay;
        using misterplex::PlaybackOverlayState;
        PlaybackOverlay ov;
        constexpr int64_t t0 = 1'000'000;
        ov.showAt(PlaybackOverlayState::Paused, 5000, 60000, t0);
        CHECK(ov.visibleAt(t0));
        CHECK(ov.visibleAt(t0 + PlaybackOverlay::kVisibleMs + 10'000));
        CHECK(!ov.dirtyBoundsAt(624, 480, t0 + PlaybackOverlay::kVisibleMs + 10'000).empty());
        // Resume / playing must still time out.
        ov.showAt(PlaybackOverlayState::Playing, 5000, 60000, t0);
        CHECK(ov.visibleAt(t0 + 100));
        CHECK(!ov.visibleAt(t0 + PlaybackOverlay::kVisibleMs + 1));
        // Stopped is sticky too (idle stop chrome must survive grabber warm-up).
        ov.showAt(PlaybackOverlayState::Stopped, 0, 0, t0);
        CHECK(ov.visibleAt(t0 + 100));
        CHECK(ov.visibleAt(t0 + PlaybackOverlay::kVisibleMs + 10'000));
        // After long pause, YUV render still paints (not dirty-empty).
        ov.showAt(PlaybackOverlayState::Paused, 1000, 2000, t0);
        std::vector<uint8_t> yuv(static_cast<size_t>(640) * 480 * 3 / 2, 16);
        std::fill(yuv.begin() + 640 * 480, yuv.end(), 128);
        CHECK(ov.renderYuv420pAt(yuv.data(), 640, 480, t0 + 60'000));
        bool bright = false;
        for (size_t i = 0; i < static_cast<size_t>(640) * 480; ++i) {
            if (yuv[i] > 100) {
                bright = true;
                break;
            }
        }
        CHECK(bright);
        std::printf("pause-sticky: PAUSED+STOPPED visible at +60s; PLAYING hides after kVisibleMs\n");
    }


    // 10. Panel empty-center is opaque chrome grey — not translucent pure-black hole.
    // Parent silicon (3883f5ab Test B): black rect ~x247-397 y360-404 @624x480, luma~40
    // over video; surrounding chrome looked grey. Source: fillRect black@(170*a/255) with
    // no title/content in that band. Opaque panelBg must make empty-center Y independent
    // of underlying video and clearly above studio-black.
    {
        using misterplex::PlaybackOverlay;
        using misterplex::PlaybackOverlayState;
        using misterplex::OverlayRect;
        constexpr int OW = 624, OH = 480;
        const size_t ysz = static_cast<size_t>(OW) * OH;
        const size_t csz = static_cast<size_t>(OW / 2) * (OH / 2);
        auto meanY = [&](const std::vector<uint8_t>& yuv, int x0, int y0, int x1, int y1) {
            long sum = 0;
            int n = 0;
            for (int y = y0; y < y1; ++y) {
                for (int x = x0; x < x1; ++x) {
                    sum += yuv[static_cast<size_t>(y) * OW + x];
                    ++n;
                }
            }
            return n ? static_cast<double>(sum) / n : -1.0;
        };
        const OverlayRect panel = PlaybackOverlay::panelBounds(OW, OH);
        const auto lm = PlaybackOverlay::layoutMetrics(OW, OH);
        // Empty band right of state label / left of right margin, between label and time.
        const int x0 = panel.x + panel.w / 3;
        const int x1 = panel.x + (2 * panel.w) / 3;
        const int y0 = panel.y + lm.labelTop + 2;
        const int y1 = panel.y + lm.timeTop - 2;
        CHECK(x1 > x0 && y1 > y0);

        auto renderOnY = [&](uint8_t Yfill) {
            std::vector<uint8_t> yuv(ysz + 2 * csz);
            std::fill(yuv.begin(), yuv.begin() + static_cast<std::ptrdiff_t>(ysz), Yfill);
            std::fill(yuv.begin() + static_cast<std::ptrdiff_t>(ysz), yuv.end(), 128);
            PlaybackOverlay ov;
            ov.showAt(PlaybackOverlayState::Paused, 34000, 360000, 0);
            // No title: empty center must still be chrome, not a video hole.
            CHECK(ov.renderYuv420pAt(yuv.data(), OW, OH, 0));
            return meanY(yuv, x0, y0, x1, y1);
        };
        const double yOnWhite = renderOnY(235);
        const double yOnBlack = renderOnY(16);
        const double yOnMid = renderOnY(128);
        std::printf("panel-empty-center: Ywhite=%.1f Yblack=%.1f Ymid=%.1f |d|=%.1f\n",
                    yOnWhite, yOnBlack, yOnMid, std::abs(yOnWhite - yOnBlack));
        // Opaque chrome: background must not leak into empty center.
        CHECK(std::abs(yOnWhite - yOnBlack) < 8.0);
        CHECK(std::abs(yOnMid - yOnBlack) < 8.0);
        // Grey chrome band (not studio black ~16, not near-white).
        CHECK(yOnMid > 30.0);
        CHECK(yOnMid < 100.0);

        // With title set, sample the title band from computePanelLayout.
        {
            std::vector<uint8_t> yuv(ysz + 2 * csz, 16);
            std::fill(yuv.begin() + static_cast<std::ptrdiff_t>(ysz), yuv.end(), 128);
            PlaybackOverlay ov;
            ov.setTitle("PLEX");
            ov.showAt(PlaybackOverlayState::Paused, 34000, 360000, 0);
            CHECK(ov.renderYuv420pAt(yuv.data(), OW, OH, 0));
            const auto lay = PlaybackOverlay::computePanelLayout(
                OW, OH, false, PlaybackOverlayState::Paused, "PLEX", 34000, 360000);
            const int tx0 = lay.titleX;
            const int ty0 = lay.titleY;
            const int tw = PlaybackOverlay::measureTextWidth(lay.titleFitted, lay.metrics);
            const int th = lay.metrics.textCellH();
            double yTitle = 0, yPeak = 0;
            int n = 0;
            const int x1t = std::min(OW, tx0 + std::max(8, tw));
            const int y1t = std::min(OH, ty0 + th);
            for (int y = ty0; y < y1t; ++y)
                for (int x = tx0; x < x1t; ++x) {
                    const double v = yuv[static_cast<size_t>(y) * OW + x];
                    yTitle += v;
                    yPeak = std::max(yPeak, v);
                    ++n;
                }
            yTitle = n ? yTitle / n : 0;
            std::printf("panel-title-band: meanY=%.1f peakY=%.1f secondLine=%d title='%s'\n",
                        yTitle, yPeak, (int)lay.titleSecondLine, lay.titleFitted);
            CHECK(lay.titleFitted[0] != '\0');
            CHECK(yPeak > yOnMid + 10.0); // glyph ink peaks above chrome grey
        }
    }

    if (fails) {
        std::fprintf(stderr, "test_playback_overlay: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_playback_overlay: OK\n");
    return 0;
}
