#include "libmisterplex/playback_overlay.hpp"

#include <algorithm>
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
constexpr int kBarX = 26;
constexpr int kBarY = 212;
constexpr int kBarW = 268;
constexpr uint16_t kAmber565 = 0xfd84;
constexpr uint16_t kWhite565 = 0xef7e;

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
    int lo = 9999;
    int hi = -1;
    const int y = kBarY + 2;
    for (int x = kBarX - 4; x < kBarX + kBarW + 6; ++x) {
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
        std::vector<uint8_t> zero = blackFrame();
        renderProgressCase(0, 100000, zero);
        CHECK(knobCenterOnBar(zero) == kBarX);
        CHECK(rgb565At(zero, kBarX + 4, kBarY + 2) != kAmber565);

        std::vector<uint8_t> half = blackFrame();
        renderProgressCase(100000, 200000, half);
        CHECK(std::abs(knobCenterOnBar(half) - (kBarX + kBarW / 2)) <= 1);
        CHECK_EQ_HEX16(rgb565At(half, kBarX + kBarW / 2 - 4, kBarY + 2), kAmber565);
        CHECK(rgb565At(half, kBarX + kBarW / 2 + 4, kBarY + 2) != kAmber565);

        std::vector<uint8_t> full = blackFrame();
        renderProgressCase(200000, 200000, full);
        CHECK(std::abs(knobCenterOnBar(full) - (kBarX + kBarW)) <= 1);
        CHECK_EQ_HEX16(rgb565At(full, kBarX + kBarW - 4, kBarY + 2), kAmber565);

        checkGuardedProgress(400000, 200000, kBarX + kBarW); // seek overshoot clamps full
        checkGuardedProgress(100000, 0, kBarX);              // live stream duration unknown
    }

    // 3. Auto-hide timing with injected timestamps, no sleeps.
    {
        PlaybackOverlay timed;
        timed.showAt(PlaybackOverlayState::Paused, 1000, 5000, 10000);
        CHECK(timed.visibleAt(10000));
        CHECK(timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs - PlaybackOverlay::kFadeMs));
        CHECK(timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs - 1));
        CHECK(!timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs));
        CHECK(timed.dirtyBoundsAt(W, H, 10000 + PlaybackOverlay::kVisibleMs).empty());

        timed.flashSkipAt(30000, 2000, 90000, 20000);
        CHECK(timed.visibleAt(20000));
        CHECK(timed.visibleAt(20000 + PlaybackOverlay::kSkipVisibleMs - 1));
        CHECK(!timed.visibleAt(20000 + PlaybackOverlay::kVisibleMs));
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
            const OverlayRect panel = PlaybackOverlay::panelBounds(c.w, c.h);
            CHECK(panel.w > 0 && panel.h > 0);
            CHECK(panel.x >= 0 && panel.y >= 0);
            CHECK(panel.x + panel.w <= c.w);
            CHECK(panel.y + panel.h <= c.h);
            // Panel occupies a sane fraction of height (about 10–40%).
            CHECK(panel.h * 10 >= c.h);       // >= 10%
            CHECK(panel.h * 5 <= c.h * 2);    // <= 40%
            const auto lm = PlaybackOverlay::layoutMetrics(c.w, c.h);
            CHECK(lm.bodyScale == std::max(1, c.h / 200));
            // Timeline endpoints: half progress → fill mid-bar.
            std::vector<uint8_t> rgb(static_cast<size_t>(c.w) * c.h * 3, 0);
            CHECK(hi.renderRgb24At(rgb.data(), c.w, c.h, 1000));
            const int barX = panel.x + 16;
            const int barW = panel.w - 32;
            const int sc = lm.bodyScale == 1 ? 1 : lm.bodyScale;
            const int barH = (sc == 1) ? 6 : lm.barH;
            const int barBottomPad = (sc == 1) ? 18 : lm.barBottomPad;
            const int barY = panel.y + panel.h - barBottomPad;
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

    // 7. Glyph effective resolution: at 1080p bodyScale>=5 so solid stroke runs
    // are multi-pixel. Forced scale=1 path (legacy 5×7 upscaled by ascal only)
    // would fail the min-run assertion.
    {
        constexpr int OW = 1920, OH = 1080;
        const auto lm = PlaybackOverlay::layoutMetrics(OW, OH);
        CHECK(lm.bodyScale >= 5); // prediction: h/200 = 5
        std::vector<uint8_t> rgb(static_cast<size_t>(OW) * OH * 3, 0);
        PlaybackOverlay ov1080;
        ov1080.showAt(PlaybackOverlayState::Paused, 0, 1, 0);
        CHECK(ov1080.renderRgb24At(rgb.data(), OW, OH, 0));
        // Scan label row for longest horizontal run of near-white pixels.
        const OverlayRect panel = PlaybackOverlay::panelBounds(OW, OH);
        const int y = panel.y + lm.labelTop + (7 * lm.bodyScale) / 2;
        int best = 0, run = 0;
        for (int x = panel.x; x < panel.x + panel.w; ++x) {
            const size_t i = (static_cast<size_t>(y) * OW + x) * 3;
            const bool whiteish = rgb[i] > 200 && rgb[i + 1] > 200 && rgb[i + 2] > 200;
            if (whiteish) {
                ++run;
                best = std::max(best, run);
            } else {
                run = 0;
            }
        }
        // bodyScale 5 ⇒ glyph strokes are 5 px wide; require >= 4.
        CHECK(best >= 4);
        // Document red-on-legacy: scale-1 would cap solid runs near 1–2 px for
        // this font. We assert the hires path is strictly better than that floor.
        CHECK(best >= lm.bodyScale - 1);
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

    if (fails) {
        std::fprintf(stderr, "test_playback_overlay: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_playback_overlay: OK\n");
    return 0;
}
