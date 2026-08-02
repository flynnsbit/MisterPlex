// Red-before-green gate for HUD layout at Hires24x32 @ bodyScale=2 (cell 48x64).
//
// Silicon 2b44d935: secondLine grew panel but title read as "MISTERP" with ~40%
// empty panel and NO ellipsis. RCA (host, quoted):
//   overlay_font_24x32::glyph('.') fell through default → space (same pointer).
//   fitText long titles → "MISTERP..." with three blank advances = visual MISTERP.
//
// This gate MUST fail on that defect (period ink==0 / ellipsis slots empty) and
// pass only when ellipsis dots have ink and full MISTERPLEX has 10 ink slots.
// Geometry-only checks against computePanelLayout alone are insufficient.
#include "libmisterplex/playback_overlay.hpp"
#include "libmisterplex/overlay_font_24x32.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int gFails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++gFails;                                                                            \
        }                                                                                        \
    } while (0)

static int glyphInk(const uint32_t* g) {
    int n = 0;
    for (int r = 0; r < 32; ++r)
        for (int c = 0; c < 24; ++c)
            if (g[r] & (1u << (31 - c)))
                ++n;
    return n;
}

static int slotInk(const uint8_t* Y, int W, int titleX, int titleY, int textH, int adv, int slot,
                   uint8_t thr = 100) {
    const int x0 = titleX + slot * adv;
    int ink = 0;
    for (int y = titleY; y < titleY + textH; ++y)
        for (int x = x0; x < x0 + adv; ++x)
            if (x >= 0 && x < W && Y[static_cast<size_t>(y) * W + x] >= thr)
                ++ink;
    return ink;
}

int main() {
    using namespace misterplex;
    constexpr int W = 624, H = 480;

    const auto lm = OverlayLayoutMetrics::compute(W, H);
    CHECK(lm.fontId == OverlayFontId::Hires24x32);
    CHECK(lm.bodyScale == 2);
    CHECK(lm.glyphAdvance == 26);
    const int advPx = lm.glyphAdvance * lm.bodyScale; // 52
    std::printf("METRICS font=24x32 adv=%d sc=%d advPx=%d cell=%dx%d\n", lm.glyphAdvance,
                lm.bodyScale, advPx, lm.textCellW(), lm.textCellH());

    // --- RCA anchors (fail on 2b44d935 font without '.') ---
    CHECK(overlay_font_24x32::glyph('.') != overlay_font_24x32::glyph(' '));
    const int periodInk = glyphInk(overlay_font_24x32::glyph('.'));
    std::printf("PERIOD_GLYPH_INK=%d (0 was 2b44d935 RED)\n", periodInk);
    CHECK(periodInk >= 8);

    // PREREG widths
    const int twFull = PlaybackOverlay::measureTextWidth("MISTERPLEX", lm);
    const int tw7 = PlaybackOverlay::measureTextWidth("MISTERP", lm);
    const int twEll = PlaybackOverlay::measureTextWidth("MISTERP...", lm);
    std::printf("PREREG tw MISTERPLEX=%d MISTERP=%d MISTERP...=%d advPx=%d\n", twFull, tw7, twEll,
                advPx);
    CHECK(twFull == 10 * advPx - lm.bodyScale); // n*adv*sc - sc
    CHECK(twFull == 518);
    CHECK(tw7 == 362);
    CHECK(twEll == 518);

    auto Lfull = PlaybackOverlay::computePanelLayout(W, H, false, PlaybackOverlayState::Paused,
                                                     "MISTERPLEX", 30016, 30016);
    std::printf("LAYOUT full secondLine=%d titleMaxW=%d fitted='%s' panelW=%d\n",
                (int)Lfull.titleSecondLine, Lfull.titleMaxW, Lfull.titleFitted, Lfull.panel.w);
    CHECK(Lfull.titleSecondLine);
    CHECK(Lfull.titleMaxW == Lfull.panel.w - 2 * std::max(14, 7 * lm.bodyScale));
    CHECK(Lfull.titleMaxW >= twFull);
    CHECK(std::strcmp(Lfull.titleFitted, "MISTERPLEX") == 0);
    CHECK(Lfull.stringsFitPanel());

    // Long title → ellipsis path (device-class: media title longer than budget)
    const char* longTitle = "MisterPlex The Long Title That Must Ellipsize";
    auto Llong = PlaybackOverlay::computePanelLayout(W, H, false, PlaybackOverlayState::Paused,
                                                     longTitle, 52000, 30016);
    std::printf("LAYOUT long fitted='%s' titleMaxW=%d second=%d elapsed='%s' total='%s'\n",
                Llong.titleFitted, Llong.titleMaxW, (int)Llong.titleSecondLine, Llong.elapsed,
                Llong.total);
    CHECK(Llong.titleSecondLine);
    CHECK(std::strstr(Llong.titleFitted, "...") != nullptr);
    // Elapsed clamp: pos 52000 dur 30016 → both 0:30 (bar already clamped)
    CHECK(std::strcmp(Llong.elapsed, "0:30") == 0);
    CHECK(std::strcmp(Llong.total, "0:30") == 0);

    // --- PIXEL path (what silicon showed) ---
    auto paint = [&](const char* title, int64_t pos, int64_t dur) {
        std::vector<uint8_t> yuv(static_cast<size_t>(W) * H * 3 / 2, 128);
        std::memset(yuv.data(), 16, static_cast<size_t>(W) * H);
        PlaybackOverlay ov;
        ov.setTitle(title);
        ov.showAt(PlaybackOverlayState::Paused, pos, dur, 0);
        CHECK(ov.renderYuv420pAt(yuv.data(), W, H, 0));
        return yuv;
    };

    // Full product title MISTERPLEX: 10 ink slots (not 7)
    {
        auto yuv = paint("MISTERPLEX", 30016, 30016);
        const uint8_t* Y = yuv.data();
        int nonempty = 0;
        for (int i = 0; Lfull.titleFitted[i]; ++i) {
            const int ink =
                slotInk(Y, W, Lfull.titleX, Lfull.titleY, lm.textCellH(), advPx, i);
            std::printf("FULL slot[%d] '%c' ink=%d\n", i, Lfull.titleFitted[i], ink);
            if (ink > 50)
                ++nonempty;
        }
        CHECK(nonempty == 10);
    }

    // Long title: fitted MISTERP... must have ink in '.' slots — this is the
    // 2b44d935 RED (period→space left slots 7..9 empty → glass "MISTERP").
    {
        auto yuv = paint(longTitle, 52000, 30016);
        const uint8_t* Y = yuv.data();
        CHECK(std::strcmp(Llong.titleFitted, "MISTERP...") == 0 ||
              std::strstr(Llong.titleFitted, "...") != nullptr);
        int nonempty = 0;
        int dotInk = 0;
        for (int i = 0; Llong.titleFitted[i]; ++i) {
            const int ink =
                slotInk(Y, W, Llong.titleX, Llong.titleY, lm.textCellH(), advPx, i);
            std::printf("LONG slot[%d] '%c' ink=%d\n", i, Llong.titleFitted[i], ink);
            if (ink > 50)
                ++nonempty;
            if (Llong.titleFitted[i] == '.')
                dotInk += ink;
        }
        std::printf("LONG nonempty=%d dotInk=%d (dotInk==0 was silicon MISTERP)\n", nonempty,
                    dotInk);
        CHECK(dotInk > 50);     // ellipsis visible
        CHECK(nonempty >= 10);  // letters + dots
        // Explicit anti-MISTERP: must not look like only 7 letter slots
        CHECK(nonempty != 7);
    }

    // Elapsed/bar agreement on painted time row is covered by clamp above.
    // OLD same-line budget still broken for documentation:
    {
        const int pad = std::max(14, 7 * lm.bodyScale);
        const auto panel = PlaybackOverlay::panelBounds(W, H);
        const int stateW = PlaybackOverlay::measureTextWidth("PAUSED", lm);
        const int iconX = panel.x + pad;
        const int stateX = iconX + 14 + 8 * 2;
        const int sameLineX = stateX + stateW + std::max(10, 6 * lm.bodyScale);
        const int sameMax = panel.x + panel.w - pad - sameLineX;
        std::printf("OLD_SAME_LINE avail=%d need=%d (still < → secondLine required)\n", sameMax,
                    twFull);
        CHECK(sameMax < twFull);
    }

    if (gFails) {
        std::printf("test_overlay_layout_fit: %d FAIL(s)\n", gFails);
        return 1;
    }
    std::printf("test_overlay_layout_fit: PASS\n");
    std::printf("RCA: period glyph was space on 2b44d935; ellipsis advances blank → MISTERP.\n");
    std::printf("DURATION: elapsed clamped to duration (matches bar min(pos,dur)); "
                "0:52 vs 0:30 was unclamped wall positionMs.\n");
    return 0;
}
