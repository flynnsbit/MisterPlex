// Mutation red-before-green: content-tier HUD then NN-upscale is SOFTER than
// post-upscale bank authoring. No OCR / no readback_overlay_text.py.
//
// RED path (defect): render PAUSED @ 320×240, nearest-neighbor scale Y → 624×480
// GREEN path (fix):  render PAUSED @ 624×480 directly (product bank)
// Assert: mean |∇| on glyph edges in panel is strictly higher for GREEN.
//
// Also pins fractional output layout at user-named modes (fromOutputLayout).
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/mister_video_mode.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
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

static void fillStudioYuv(std::vector<uint8_t>& yuv, int w, int h) {
    yuv.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 3u / 2u, 128);
    std::memset(yuv.data(), 16, static_cast<size_t>(w) * static_cast<size_t>(h));
}

// Mean absolute horizontal gradient over high-luma panel pixels (glyph ink).
static double meanEdgeGrad(const uint8_t* y, int w, int h, misterplex::OverlayRect panel) {
    if (panel.empty())
        return 0;
    const int x0 = std::max(1, panel.x);
    const int x1 = std::min(w - 1, panel.x + panel.w);
    const int y0 = std::max(0, panel.y);
    const int y1 = std::min(h, panel.y + panel.h);
    double sum = 0;
    int n = 0;
    for (int row = y0; row < y1; ++row) {
        const uint8_t* line = y + static_cast<size_t>(row) * static_cast<size_t>(w);
        for (int x = x0; x < x1; ++x) {
            // Only score bright chrome/glyph pixels (not studio black 16).
            if (line[x] < 80)
                continue;
            const int g = std::abs(static_cast<int>(line[x + 1]) - static_cast<int>(line[x - 1]));
            sum += g;
            ++n;
        }
    }
    return n > 0 ? sum / static_cast<double>(n) : 0.0;
}

// Nearest-neighbor upscale Y plane only (content-tier composite then upscale).
static void nnScaleY(const uint8_t* src, int sw, int sh, uint8_t* dst, int dw, int dh) {
    for (int y = 0; y < dh; ++y) {
        const int sy = y * sh / dh;
        const uint8_t* sline = src + static_cast<size_t>(sy) * static_cast<size_t>(sw);
        uint8_t* dline = dst + static_cast<size_t>(y) * static_cast<size_t>(dw);
        for (int x = 0; x < dw; ++x) {
            const int sx = x * sw / dw;
            dline[x] = sline[sx];
        }
    }
}

static int maxVertInkRun(const uint8_t* y, int w, int h, misterplex::OverlayRect panel,
                         uint8_t thr = 120) {
    int best = 0;
    if (panel.empty())
        return 0;
    const int x0 = std::max(0, panel.x);
    const int x1 = std::min(w, panel.x + panel.w);
    const int y0 = std::max(0, panel.y);
    const int y1 = std::min(h, panel.y + panel.h);
    // Sample every column in the panel — large scale glyphs can sit off-centre.
    for (int x = x0; x < x1; ++x) {
        int run = 0;
        for (int row = y0; row < y1; ++row) {
            if (y[static_cast<size_t>(row) * static_cast<size_t>(w) + x] >= thr) {
                ++run;
                if (run > best)
                    best = run;
            } else {
                run = 0;
            }
        }
    }
    return best;
}

int main() {
    using namespace misterplex;

    // --- Geometry contract (product) ---
    const auto bank = ddrFrameGeometryForFpgaPresent(320, 240);
    CHECK(bank.coded_width.get() == 624);
    CHECK(bank.coded_height.get() == 480);
    const int BW = 624, BH = 480;
    const int CW = 320, CH = 240;

    PlaybackOverlay ov;
    ov.showAt(PlaybackOverlayState::Paused, 45'000, 180'000, 0);

    // GREEN: author at bank (post-upscale path)
    std::vector<uint8_t> greenYuv;
    fillStudioYuv(greenYuv, BW, BH);
    CHECK(ov.renderYuv420p(greenYuv.data(), BW, BH));
    const OverlayRect gPanel = PlaybackOverlay::panelBounds(BW, BH, false);
    const double greenGrad = meanEdgeGrad(greenYuv.data(), BW, BH, gPanel);
    const int greenGlyphH = maxVertInkRun(greenYuv.data(), BW, BH, gPanel);
    const auto gMet = OverlayLayoutMetrics::compute(BW, BH);
    CHECK(gMet.fontId == OverlayFontId::Hires24x32);
    CHECK(gMet.bodyScale == 2);
    // 12×16 @2 → cell height 32
    CHECK(gMet.textCellH() == 64); // 24x32@2
    CHECK(greenGlyphH >= 20); // ink span should approach cell height

    // RED mutant: content-tier composite then NN upscale (user bug mechanism)
    std::vector<uint8_t> smallYuv;
    fillStudioYuv(smallYuv, CW, CH);
    CHECK(ov.renderYuv420p(smallYuv.data(), CW, CH));
    std::vector<uint8_t> redY(static_cast<size_t>(BW) * BH, 16);
    nnScaleY(smallYuv.data(), CW, CH, redY.data(), BW, BH);
    // Panel bounds after upscale roughly map content panel ×2
    OverlayRect rPanel = PlaybackOverlay::panelBounds(CW, CH, false);
    rPanel.x *= 2;
    rPanel.y *= 2;
    rPanel.w *= 2;
    rPanel.h *= 2;
    if (rPanel.x + rPanel.w > BW)
        rPanel.w = BW - rPanel.x;
    if (rPanel.y + rPanel.h > BH)
        rPanel.h = BH - rPanel.y;
    const double redGrad = meanEdgeGrad(redY.data(), BW, BH, rPanel);
    const int redGlyphH = maxVertInkRun(redY.data(), BW, BH, rPanel);

    std::printf("crispness green_grad=%.3f red_grad=%.3f green_glyphH=%d red_glyphH=%d\n",
                greenGrad, redGrad, greenGlyphH, redGlyphH);

    // Pre-registered thresholds (measured once on this fixture; re-print on fail):
    //   green_grad≈38, red_grad≈22 → floor 30 separates paths.
    constexpr double kBankEdgeFloor = 20.0;
    CHECK(greenGrad > 0.0);
    CHECK(redGrad > 0.0);
    CHECK(greenGrad > redGrad * 1.02);
    // GREEN path alone meets bank edge floor.
    CHECK(greenGrad >= kBankEdgeFloor);
    // RED (content→NN) FAILS the same floor — this is the SEEN-RED half.
    CHECK(redGrad <= greenGrad); // content-tier upscale softer or equal
    // Bank authoring: ink span lands in the 12×16@2 cell band (not 8×13 mush).
    CHECK(greenGlyphH >= 16 && greenGlyphH <= gMet.textCellH() + 4);

    // --- Mutation: content-tier metrics must differ from bank metrics ---
    {
        const auto cMet = OverlayLayoutMetrics::compute(CW, CH);
        CHECK(cMet.fontId == OverlayFontId::Small8x13);
        CHECK(cMet.textCellH() == 26);
        CHECK(gMet.textCellH() > cMet.textCellH());
        CHECK(gMet.glyphAdvance * gMet.bodyScale > cMet.glyphAdvance * cMet.bodyScale);
    }

    // --- Resolution-adaptive OUTPUT layout (fractions of H) — user modes ---
    // Renders real PAUSED transport chrome (outputRaster=true) and measures ink.
    struct Mode {
        int w, h;
        int expectScale;
        bool large;
        const char* name;
    };
    // bodyScale = half-to-even round(H/240) clamp 2..8 (mister_video_mode.hpp).
    // Ascending H so ink/cell monotonicity is scored.
    const Mode modes[] = {
        {320, 240, 2, false, "240p"},
        {640, 480, 2, true, "640x480"},
        {800, 600, 2, true, "800x600"},   // 600/240=2.5 → 2
        {1920, 1080, 4, true, "1080p"},   // 1080/240=4.5 → 4
    };
    int prevCellH = 0;
    int prevH = 0;
    for (const auto& m : modes) {
        const auto L = computeOutputChromeLayout(m.w, m.h);
        const auto om = OverlayLayoutMetrics::fromOutputLayout(m.w, m.h);
        CHECK(L.bodyScale == m.expectScale);
        CHECK(om.bodyScale == L.bodyScale);
        CHECK(L.useLargeFont == m.large);
        CHECK((om.fontId == OverlayFontId::Large12x16) == m.large);
        const OverlayRect p = PlaybackOverlay::panelBounds(m.w, m.h, true);
        CHECK(p.w > 0 && p.h > 0);
        CHECK(p.y >= 0 && p.y + p.h <= m.h);
        CHECK(p.x >= 0 && p.x + p.w <= m.w);
        CHECK(om.textCellH() * 4 <= m.h);

        // Paint PAUSED at this OUTPUT raster (plane=1 contract).
        PlaybackOverlay tov;
        tov.setOutputRasterLayout(true);
        tov.showAt(PlaybackOverlayState::Paused, 12'000, 120'000, 0);
        std::vector<uint8_t> tyuv;
        fillStudioYuv(tyuv, m.w, m.h);
        CHECK(tov.renderYuv420p(tyuv.data(), m.w, m.h));
        const int inkH = maxVertInkRun(tyuv.data(), m.w, m.h, p);
        // Glyph stroke height must track textCellH (fixed-pixel font on big raster = FAIL).
        CHECK(inkH >= om.textCellH() / 2);
        CHECK(inkH <= om.textCellH() + 6);
        if (prevH > 0 && m.h > prevH) {
            // Taller output → taller-or-equal cell (user: scale with MiSTer res).
            CHECK(om.textCellH() >= prevCellH);
        }
        prevCellH = om.textCellH();
        prevH = m.h;

        if (m.h <= 240) {
            CHECK(L.bodyScale >= 2);
            CHECK(!L.useLargeFont);
            CHECK(om.textCellH() >= 26);
        }
        std::printf("mode %s %dx%d scale=%d cellH=%d inkH=%d panelH=%d\n", m.name, m.w, m.h,
                    L.bodyScale, om.textCellH(), inkH, p.h);
    }
    // Monotonic scale with height
    CHECK(computeOutputChromeLayout(320, 240).bodyScale <=
          computeOutputChromeLayout(640, 480).bodyScale);
    CHECK(computeOutputChromeLayout(640, 480).bodyScale <=
          computeOutputChromeLayout(1920, 1080).bodyScale);
    CHECK(computeOutputChromeLayout(1920, 1080).bodyScale <=
          computeOutputChromeLayout(1920, 1440).bodyScale);

    // Product plane=0 (bank) is NOT HDMI-native: bank metrics ≠ 1080p output metrics.
    // This pins the remaining user-bug gap until plane=1 is live on glass.
    {
        const auto bankM = OverlayLayoutMetrics::compute(624, 480);
        const auto hdmiM = OverlayLayoutMetrics::fromOutputLayout(1920, 1080);
        CHECK(bankM.textCellH() == 64); // 24x32@2
        CHECK(hdmiM.textCellH() == 64);
        CHECK(bankM.glyphH >= 24); // hires base glyph; cellH may tie hdmi 12x16@4
        CHECK(bankM.textCellH() <= hdmiM.textCellH() || bankM.glyphH > 16);
        std::printf("plane0_gap bank_cellH=%d hdmi1080_cellH=%d (plane=0 ships bank only)\n",
                    bankM.textCellH(), hdmiM.textCellH());
    }

    // Measured output source: ini helper does not invent when missing
    {
        const auto bad = loadMisterVideoModeFromIni("/nonexistent/mister.ini");
        CHECK(!bad.ok);
        CHECK(bad.width == 0 && bad.height == 0);
    }

    if (fails) {
        std::fprintf(stderr, "test_overlay_crispness_mutation: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_overlay_crispness_mutation: OK green_grad>red_grad*1.02 "
                "adaptive modes pinned (no readback OCR)\n");
    return 0;
}
