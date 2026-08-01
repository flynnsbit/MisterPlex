// RED-before-GREEN: player chrome must author at PRESENT/coded bank geometry
// (post FFmpeg upscale), never at DECODE/content tier.
//
// Defect (main + older live): ddrFrameGeometryForPresentedSize(DECODE) returned
// identity 320×240 when DECODE≠640×480 presented → overlay metrics/glyph grid
// matched content, then looked soft after core stretch.
//
// Fix contract: ddrFrameGeometryForFpgaPresent(any) → plex480p 624×480 bank;
// PlaybackOverlay::compute(624,480) ≠ compute(320,240).
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

// Horizontal run-length of first non-studio-ish ink on a Y scanline inside panel.
static int firstInkRun(const uint8_t* y, int w, int row, int x0, int x1, uint8_t thr) {
    const uint8_t* line = y + static_cast<size_t>(row) * static_cast<size_t>(w);
    int run = 0;
    bool in = false;
    int best = 0;
    for (int x = x0; x < x1; ++x) {
        if (line[x] >= thr) {
            if (!in) {
                in = true;
                run = 1;
            } else {
                ++run;
            }
            if (run > best)
                best = run;
        } else {
            in = false;
            run = 0;
        }
    }
    return best;
}

int main() {
    using namespace misterplex;

    // --- Geometry selection (the load-bearing contract) ---
    // DECODE conf on device is often 320×240; canvas must still be silicon bank.
    const DdrFrameGeometry g320 = ddrFrameGeometryForFpgaPresent(320, 240);
    CHECK(g320.coded_width.get() == 624);
    CHECK(g320.coded_height.get() == 480);
    CHECK(g320.presented_width.get() == 640);
    CHECK(g320.presented_height.get() == 480);

    // Identity-at-decode is the RED twin of the old path (presented-size helper
    // when DECODE≠640×480). Must remain unequal to FpgaPresent.
    const DdrFrameGeometry gId = makeDdrFrameGeometry(320, 240);
    CHECK(gId.coded_width.get() == 320);
    CHECK(gId.coded_height.get() == 240);
    CHECK(gId.coded_width.get() != g320.coded_width.get());

    // plex480p pin used by idle/pause
    const DdrFrameGeometry gIdle = plex480pDdrFrameGeometry();
    CHECK(gIdle.coded_width.get() == 624 && gIdle.coded_height.get() == 480);

    // --- Layout metrics: content tier vs present bank ---
    const auto mContent = OverlayLayoutMetrics::compute(320, 240);
    const auto mPresent = OverlayLayoutMetrics::compute(624, 480);
    CHECK(mContent.fontId == OverlayFontId::Small8x13);
    CHECK(mPresent.fontId == OverlayFontId::Large12x16);
    CHECK(mPresent.bodyScale >= 2);
    CHECK(mPresent.glyphAdvance * mPresent.bodyScale == 26); // 13*2
    CHECK(mContent.glyphAdvance * mContent.bodyScale == 18); // 9*2
    // Discriminator: present-bank advance is strictly larger than content-tier.
    CHECK(mPresent.glyphAdvance * mPresent.bodyScale >
          mContent.glyphAdvance * mContent.bodyScale);

    // --- Raster: PAUSED chrome on both canvases; ink run tracks body scale ---
    PlaybackOverlay ov;
    ov.showAt(PlaybackOverlayState::Paused, 30'000, 120'000, /*now*/ 0);

    auto paintY = [&](int w, int h) {
        std::vector<uint8_t> yuv(static_cast<size_t>(w) * static_cast<size_t>(h) * 3u / 2u);
        // studio black-ish
        std::memset(yuv.data(), 16, static_cast<size_t>(w) * static_cast<size_t>(h));
        std::memset(yuv.data() + static_cast<size_t>(w) * h, 128, yuv.size() - static_cast<size_t>(w) * h);
        CHECK(ov.renderYuv420p(yuv.data(), w, h));
        return yuv;
    };

    auto y320 = paintY(320, 240);
    auto y624 = paintY(624, 480);
    const OverlayRect p320 = PlaybackOverlay::panelBounds(320, 240);
    const OverlayRect p624 = PlaybackOverlay::panelBounds(624, 480);
    CHECK(!p320.empty() && !p624.empty());
    CHECK(p624.w > p320.w);
    CHECK(p624.h >= p320.h);

    // Sample a mid-panel row for white-ish glyph ink (Y high).
    const int row320 = p320.y + p320.h / 3;
    const int row624 = p624.y + p624.h / 3;
    const int run320 = firstInkRun(y320.data(), 320, row320, p320.x, p320.x + p320.w, 180);
    const int run624 = firstInkRun(y624.data(), 624, row624, p624.x, p624.x + p624.w, 180);
    CHECK(run320 > 0);
    CHECK(run624 > 0);
    // 12×16@2 strokes are thicker / longer runs than 8×13@2 on average.
    // Require present bank not to collapse to content-tier max run.
    CHECK(run624 >= run320);

    // 240p-class present canvas policy: small font, panel in-bounds
    const auto m240 = OverlayLayoutMetrics::compute(320, 240);
    CHECK(m240.fontId == OverlayFontId::Small8x13);
    const OverlayRect p240 = PlaybackOverlay::panelBounds(320, 240);
    CHECK(p240.y >= 0 && p240.y + p240.h <= 240);
    CHECK(p240.x >= 0 && p240.x + p240.w <= 320);

    // 640×480 present canvas (user-named mode)
    const auto m640 = OverlayLayoutMetrics::compute(640, 480);
    CHECK(m640.fontId == OverlayFontId::Large12x16);
    CHECK(m640.bodyScale == 2);

    // 800×600
    const auto m800 = OverlayLayoutMetrics::compute(800, 600);
    CHECK(m800.bodyScale >= 2);
    const OverlayRect p800 = PlaybackOverlay::panelBounds(800, 600);
    CHECK(p800.y + p800.h <= 600);

    if (fails) {
        std::fprintf(stderr, "test_overlay_post_upscale: %d FAIL\n", fails);
        return 1;
    }
    std::printf(
        "test_overlay_post_upscale: OK fpga_present(320→624x480) "
        "metrics present>content run624=%d run320=%d\n",
        run624, run320);
    return 0;
}
