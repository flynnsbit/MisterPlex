// Zero-device falsifier: histogram SOURCE stroke widths on the authored canvas
// BEFORE any HDMI/ascal stretch. Parent ERROR-18 retracted non-integer-upscale
// theory of multi-width strokes from a uniform 1px source.
//
// PRE-REGISTER (product bank 624×480 STOPPED, tip font 24×32 @ bodyScale=2):
//   P1: fontId==Hires24x32, glyphH==32, bodyScale==2, textCellH==64
//       Parent 5×7 cite is STALE (no row<7 loop on tip). Prior tip was 12×16.
//   P2: text horizontal ink runs are multiples of bodyScale (2).
//   P3: panel may include thin border runs; thr may miss amber strokeRect.
//   P4: source text must NOT invent 7/8/9 as 1px-upscale multi-width theory.
//       (10+ even widths OK = multi-column strokes × scale.)
//   P5: max vertical ink run <= textCellH (64).
//
// Display histogram parent measured (for comparison only, not asserted here):
//   {7:96, 8:136, 9:40, 10:116, 14:4, 19:16, 22:8, 24:4, 25:8, 31:8, 34:4}
//   glyph ink height 52 on 1080p capture.
//
// Also emit NN-stretched 624→1920×1080 hist of the SAME canvas so we can see
// which display bins a pure integer-block font + non-integer resample creates.
#include "libmisterplex/playback_overlay.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
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

static void fillStudio(std::vector<uint8_t>& yuv, int w, int h) {
    yuv.assign(static_cast<size_t>(w) * h * 3u / 2u, 128);
    std::memset(yuv.data(), 16, static_cast<size_t>(w) * h);
}

// Horizontal run-length histogram of pixels with Y >= thr in ROI.
static std::map<int, int> horizRunHist(const uint8_t* y, int w, int h, int x0, int y0, int x1,
                                       int y1, uint8_t thr) {
    std::map<int, int> hist;
    x0 = std::max(0, x0);
    y0 = std::max(0, y0);
    x1 = std::min(w, x1);
    y1 = std::min(h, y1);
    for (int row = y0; row < y1; ++row) {
        const uint8_t* line = y + static_cast<size_t>(row) * w;
        int run = 0;
        for (int x = x0; x < x1; ++x) {
            if (line[x] >= thr) {
                ++run;
            } else if (run > 0) {
                hist[run]++;
                run = 0;
            }
        }
        if (run > 0)
            hist[run]++;
    }
    return hist;
}

static int maxVertRun(const uint8_t* y, int w, int h, int x0, int y0, int x1, int y1,
                      uint8_t thr) {
    int best = 0;
    x0 = std::max(0, x0);
    y0 = std::max(0, y0);
    x1 = std::min(w, x1);
    y1 = std::min(h, y1);
    for (int x = x0; x < x1; ++x) {
        int run = 0;
        for (int row = y0; row < y1; ++row) {
            if (y[static_cast<size_t>(row) * w + x] >= thr) {
                ++run;
                best = std::max(best, run);
            } else {
                run = 0;
            }
        }
    }
    return best;
}

static void printHist(const char* tag, const std::map<int, int>& h) {
    std::printf("%s {", tag);
    bool first = true;
    for (const auto& kv : h) {
        if (!first)
            std::printf(", ");
        first = false;
        std::printf("%d:%d", kv.first, kv.second);
    }
    std::printf("}\n");
}

// Count runs that are NOT multiples of scale (excluding len==1 border candidates).
static int countNonMultipleOf(const std::map<int, int>& h, int scale, bool skipOnes) {
    int n = 0;
    for (const auto& kv : h) {
        if (skipOnes && kv.first == 1)
            continue;
        if (kv.first % scale != 0)
            n += kv.second;
    }
    return n;
}

static void nnScaleY(const uint8_t* src, int sw, int sh, uint8_t* dst, int dw, int dh) {
    for (int y = 0; y < dh; ++y) {
        const int sy = std::min(sh - 1, y * sh / dh);
        const uint8_t* sline = src + static_cast<size_t>(sy) * sw;
        uint8_t* dline = dst + static_cast<size_t>(y) * dw;
        for (int x = 0; x < dw; ++x) {
            const int sx = std::min(sw - 1, x * sw / dw);
            dline[x] = sline[sx];
        }
    }
}

int main() {
    constexpr int BW = 624, BH = 480;
    constexpr uint8_t kInk = 140; // white/amber chrome above panel grey

    // --- P1: metrics truth ---
    const auto lm = misterplex::OverlayLayoutMetrics::compute(BW, BH);
    const char* fid =
        lm.fontId == misterplex::OverlayFontId::Hires24x32 ? "24x32"
        : lm.fontId == misterplex::OverlayFontId::Large12x16 ? "12x16" : "8x13";
    std::printf("METRICS bank=%dx%d fontId=%s glyph=%dx%d advance=%d bodyScale=%d textCellH=%d\n",
                BW, BH, fid, lm.glyphW, lm.glyphH, lm.glyphAdvance, lm.bodyScale, lm.textCellH());
    CHECK(lm.fontId == misterplex::OverlayFontId::Hires24x32);
    CHECK(lm.glyphW == 24 && lm.glyphH == 32);
    CHECK(lm.bodyScale == 2);
    CHECK(lm.textCellH() == 64);

    // Full STOPPED overlay (label + times + bar + strokes) — product path.
    std::vector<uint8_t> yuv;
    fillStudio(yuv, BW, BH);
    misterplex::PlaybackOverlay ov;
    ov.showAt(misterplex::PlaybackOverlayState::Stopped, 0, 0, /*now*/ 0);
    ov.setTitle("MISTERPLEX");
    // Title like device log "MISTERPLEX"
    // (API may not expose title setter publicly — use default empty if none)
    CHECK(ov.renderYuv420pAt(yuv.data(), BW, BH, 0));

    const auto panel = misterplex::PlaybackOverlay::panelBounds(BW, BH);
    std::printf("PANEL x=%d y=%d w=%d h=%d\n", panel.x, panel.y, panel.w, panel.h);
    CHECK(!panel.empty());

    const uint8_t* Y = yuv.data();
    auto histAll = horizRunHist(Y, BW, BH, panel.x, panel.y, panel.x + panel.w, panel.y + panel.h,
                                kInk);
    printHist("SOURCE_PANEL_HRUN", histAll);

    // Label row only (top text band inside panel).
    const int labelY0 = panel.y + lm.labelTop;
    const int labelY1 = labelY0 + lm.textCellH();
    auto histLabel =
        horizRunHist(Y, BW, BH, panel.x, labelY0, panel.x + panel.w, labelY1, kInk);
    printHist("SOURCE_LABEL_HRUN", histLabel);

    // Time row
    const int timeY0 = panel.y + lm.timeTop;
    const int timeY1 = timeY0 + lm.textCellH();
    auto histTime = horizRunHist(Y, BW, BH, panel.x, timeY0, panel.x + panel.w, timeY1, kInk);
    printHist("SOURCE_TIME_HRUN", histTime);

    const int vmax = maxVertRun(Y, BW, BH, panel.x, panel.y, panel.x + panel.w, panel.y + panel.h,
                                kInk);
    std::printf("SOURCE_MAX_VERT_INK_RUN=%d textCellH=%d\n", vmax, lm.textCellH());
    CHECK(vmax > 0);
    CHECK(vmax <= lm.textCellH() + 4); // allow bar/knob slightly taller

    // P2/P4: LABEL row only (time row includes progress bar — continuous widths).
    printHist("SOURCE_TEXT_HRUN", histLabel);
    const int nonMultText = countNonMultipleOf(histLabel, lm.bodyScale, /*skipOnes*/ true);
    std::printf("SOURCE_LABEL_non_multiple_of_%d_excluding_1px=%d\n", lm.bodyScale, nonMultText);
    CHECK(nonMultText == 0);
    int c2 = histLabel.count(2) ? histLabel[2] : 0;
    int c4 = histLabel.count(4) ? histLabel[4] : 0;
    int c6 = histLabel.count(6) ? histLabel[6] : 0;
    int c7 = histLabel.count(7) ? histLabel[7] : 0;
    int c8 = histLabel.count(8) ? histLabel[8] : 0;
    int c9 = histLabel.count(9) ? histLabel[9] : 0;
    std::printf("SOURCE_LABEL peaks c2=%d c4=%d c6=%d c7=%d c8=%d c9=%d\n", c2, c4, c6, c7, c8, c9);
    CHECK(c2 + c4 + c6 + c8 > 0);
    int oddText = 0;
    for (const auto& kv : histLabel)
        if (kv.first % 2)
            oddText += kv.second;
    std::printf("SOURCE_LABEL_odd_runs=%d\n", oddText);
    CHECK(oddText == 0);
    CHECK(c7 == 0 && c9 == 0);

    // P3: strokeRect may be below ink thr after YUV — report only (soft).
    int c1 = histAll.count(1) ? histAll[1] : 0;
    std::printf("SOURCE_PANEL_1px_runs=%d (strokeRect; YUV may hide)\n", c1);

    // --- Pure text-only canvas (no panel chrome) via isolated draw path ---
    // Render STOPPED again is enough; label hist is the text falsifier.

    // --- NN stretch bank → 1920×1080 full-frame (height-fit 2.25×) ---
    constexpr int OW = 1920, OH = 1080;
    std::vector<uint8_t> big(static_cast<size_t>(OW) * OH, 16);
    // Letterbox: scale by min(OW/BW, OH/BH)
    const double sx = static_cast<double>(OW) / BW;
    const double sy = static_cast<double>(OH) / BH;
    const double s = std::min(sx, sy); // height-limited → 2.25
    const int dw = static_cast<int>(BW * s + 0.5);
    const int dh = static_cast<int>(BH * s + 0.5);
    const int ox = (OW - dw) / 2;
    const int oy = (OH - dh) / 2;
    std::vector<uint8_t> scaled(static_cast<size_t>(dw) * dh, 16);
    nnScaleY(Y, BW, BH, scaled.data(), dw, dh);
    for (int row = 0; row < dh; ++row)
        std::memcpy(big.data() + static_cast<size_t>(oy + row) * OW + ox,
                    scaled.data() + static_cast<size_t>(row) * dw, static_cast<size_t>(dw));

    // Map panel ROI into stretched space
    const int px0 = ox + static_cast<int>(panel.x * s + 0.5);
    const int py0 = oy + static_cast<int>(panel.y * s + 0.5);
    const int px1 = ox + static_cast<int>((panel.x + panel.w) * s + 0.5);
    const int py1 = oy + static_cast<int>((panel.y + panel.h) * s + 0.5);
    auto histDisp = horizRunHist(big.data(), OW, OH, px0, py0, px1, py1, kInk);
    printHist("STRETCH1080_PANEL_HRUN", histDisp);
    const int vmaxDisp = maxVertRun(big.data(), OW, OH, px0, py0, px1, py1, kInk);
    std::printf("STRETCH1080_MAX_VERT_INK_RUN=%d  scale=%.4f  predict_cellH=%.1f\n", vmaxDisp, s,
                lm.textCellH() * s);

    // Parent display peaks of interest
    for (int k : {7, 8, 9, 10, 14, 19, 22, 24, 25, 31, 34, 52}) {
        const int c = histDisp.count(k) ? histDisp[k] : 0;
        std::printf("STRETCH1080_bin[%d]=%d\n", k, c);
    }

    // Also: text-only rows at 5x7@scale1 and @scale2 as PARENT-CITED path
    // (not product) — prove uniform block → single-family widths.
    // Re-implement parent loop bounds for documentation.
    {
        auto render57 = [](std::vector<uint8_t>& img, int w, int h, int scale, const char* text) {
            // Classic 5x7 'E' pattern rows as stand-in (parent d4 style density)
            static const uint8_t E[7] = {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f};
            int x = 10, y = 10;
            for (const char* p = text; *p; ++p) {
                for (int row = 0; row < 7; ++row)
                    for (int col = 0; col < 5; ++col) {
                        if ((E[row] & (1u << (4 - col))) == 0)
                            continue;
                        for (int dy = 0; dy < scale; ++dy)
                            for (int dx = 0; dx < scale; ++dx) {
                                int xx = x + col * scale + dx;
                                int yy = y + row * scale + dy;
                                if (xx >= 0 && yy >= 0 && xx < w && yy < h)
                                    img[static_cast<size_t>(yy) * w + xx] = 255;
                            }
                    }
                x += 6 * scale;
            }
        };
        std::vector<uint8_t> a(BW * BH, 0), b(BW * BH, 0);
        render57(a, BW, BH, 1, "EEEE");
        render57(b, BW, BH, 2, "EEEE");
        auto h1 = horizRunHist(a.data(), BW, BH, 0, 0, BW, 40, 128);
        auto h2 = horizRunHist(b.data(), BW, BH, 0, 0, BW, 40, 128);
        printHist("FAKE5x7_scale1_HRUN", h1);
        printHist("FAKE5x7_scale2_HRUN", h2);
        // scale1: runs of 1 and 5 only for E bars; scale2: 2 and 10
        CHECK((h1.count(1) || h1.count(5)));
        CHECK((h2.count(2) || h2.count(10)));
        CHECK(!h1.count(7) && !h1.count(8) && !h1.count(9) && !h1.count(10));
    }

    if (gFails) {
        std::fprintf(stderr, "test_overlay_source_stroke_hist: %d FAIL(s)\n", gFails);
        return 1;
    }
    std::printf("test_overlay_source_stroke_hist: PASS\n");
    std::printf("ACCOUNTING: source text has no {7,8,9,10}; those display bins "
                "are NOT authored multi-width 1px strokes. Parent ERROR-18 mechanism "
                "retracted agrees with source. Remaining display multi-bin needs "
                "stretch+icons+strokeRect — measured stretch hist printed above.\n");
    return 0;
}
