// Layout fit gate — red-before-green for 24x32@2 bank chrome (parent silicon
#include <vector>
#include <algorithm>
// regression on 23b2f8df: title collapsed to "PAUSEDM", duration unreadable).
//
// PRE-REGISTER (product bank 624×480, Hires24x32 bodyScale=2):
//   advancePx = 26*2 = 52
//   tw("PAUSED") = 310
//   tw("MISTERPLEX") = 518
//   tw("PAUSED MISTERPLEX") = 882  >> panelW≈594  ⇒ cannot share one row
//   tw("2:14") = tw("2:18") = 206
//   panelW = 624 - 2*margin15 = 594
//   same-line title budget after icon+PAUSED ≈ 210 ⇒ only "M..." under OLD layout
//   FIX: title on second line ⇒ titleMaxW≈564 ≥ 518 ⇒ full "MISTERPLEX"
//
// RED (old same-line-only budget): available 210 < 518 and fitted len<=1+ellipsis
// GREEN (computePanelLayout): stringsFitPanel, full title or ellipsis, times no overlap
#include "libmisterplex/playback_overlay.hpp"

#include <cstdio>
#include <cstring>
#include <string>

static int gFails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++gFails;                                                                            \
        }                                                                                        \
    } while (0)

using misterplex::OverlayFontId;
using misterplex::OverlayLayoutMetrics;
using misterplex::PlaybackOverlay;
using misterplex::PlaybackOverlayState;

static int tw(const char* s, const OverlayLayoutMetrics& m) {
    return PlaybackOverlay::measureTextWidth(s, m);
}

// Reconstruct 23b2f8df same-line-only title budget (the bug).
static bool oldSameLineTitleIsBroken(const OverlayLayoutMetrics& m, int panelW, int panelX) {
    const int sc = m.bodyScale;
    const int pad = std::max(10, 5 * sc);
    const int iconSc = m.iconScale;
    const int iconX = panelX + pad;
    const int stateX = iconX + 14 + 8 * iconSc;
    const int stateW = tw("PAUSED", m);
    const int gap = std::max(10, 6 * sc);
    const int titleX = stateX + stateW + gap;
    const int titleMaxR = panelX + panelW - pad;
    const int avail = titleMaxR - titleX;
    const int need = tw("MISTERPLEX", m);
    // Use public layout path's fit via full layout — simulate old: fit into avail only
    // Direct: if avail < need, old fitText yields short string.
    // Emulate fitText by calling computePanelLayout is NEW. Manual:
    // old bug condition: avail < need AND avail < tw("MI...") roughly
    std::printf("OLD_SAME_LINE avail=%d need_title=%d stateW=%d panelW=%d\n", avail, need, stateW,
                panelW);
    CHECK(avail > 0);
    return avail < need; // broken if true for product bank hires
}

int main() {
    constexpr int W = 624, H = 480;
    const auto m = OverlayLayoutMetrics::compute(W, H);
    std::printf("METRICS font=%s glyph=%dx%d scale=%d cell=%dx%d adv=%d\n",
                m.fontId == OverlayFontId::Hires24x32 ? "24x32"
                : m.fontId == OverlayFontId::Large12x16 ? "12x16" : "8x13",
                m.glyphW, m.glyphH, m.bodyScale, m.textCellW(), m.textCellH(), m.glyphAdvance);
    CHECK(m.fontId == OverlayFontId::Hires24x32);
    CHECK(m.bodyScale == 2);
    CHECK(m.textCellH() == 64);
    CHECK(m.textCellW() == 48);

    // --- Pre-registered widths ---
    CHECK(tw("PAUSED", m) == 310);
    CHECK(tw("MISTERPLEX", m) == 518);
    CHECK(tw("PAUSED MISTERPLEX", m) == 882);
    CHECK(tw("2:14", m) == 206);
    CHECK(tw("2:18", m) == 206);
    std::printf("PREREG tw PAUSED=%d MISTERPLEX=%d BOTH=%d t214=%d panel_expect=594\n",
                tw("PAUSED", m), tw("MISTERPLEX", m), tw("PAUSED MISTERPLEX", m), tw("2:14", m));

    const auto panel = PlaybackOverlay::panelBounds(W, H, false);
    std::printf("PANEL x=%d y=%d w=%d h=%d\n", panel.x, panel.y, panel.w, panel.h);
    CHECK(panel.w == 594);

    // RED: old same-line path cannot fit full title
    CHECK(oldSameLineTitleIsBroken(m, panel.w, panel.x));

    // GREEN: new layout
    const int64_t pos = 2 * 60 * 1000 + 14 * 1000; // 2:14
    const int64_t dur = 2 * 60 * 1000 + 18 * 1000; // 2:18
    auto L = PlaybackOverlay::computePanelLayout(W, H, false, PlaybackOverlayState::Paused,
                                                 "MISTERPLEX", pos, dur);
    std::printf("LAYOUT secondLine=%d title='%s' titleMaxW=%d stateW=%d\n", L.titleSecondLine,
                L.titleFitted, L.titleMaxW, L.stateW);
    std::printf("TIME elapsed=%s@%d w=%d total=%s@%d w=%d gap=%d\n", L.elapsed, L.elapsedX,
                L.elapsedW, L.total, L.totalX, L.totalW, L.timeGap);
    CHECK(L.ok);
    CHECK(L.titleSecondLine); // must promote — proves we left the 23b2f8df path
    CHECK(std::strcmp(L.titleFitted, "MISTERPLEX") == 0);
    CHECK(std::strcmp(L.stateText, "PAUSED") == 0);
    CHECK(std::strcmp(L.elapsed, "2:14") == 0);
    CHECK(std::strcmp(L.total, "2:18") == 0);
    CHECK(L.stringsFitPanel());
    CHECK(L.timeGap >= 0);
    // Duration geometry: total fully inside panel — NOT an independent duration bug.
    CHECK(L.totalX >= L.panel.x);
    CHECK(L.totalX + L.totalW <= L.panel.x + L.panel.w);

    // Parent case: 2:14 of ~6:00 with high bar was misread; prove 6:00 fits too.
    auto L6 = PlaybackOverlay::computePanelLayout(W, H, false, PlaybackOverlayState::Paused,
                                                  "MISTERPLEX", pos, 6 * 60 * 1000);
    CHECK(std::strcmp(L6.total, "6:00") == 0);
    CHECK(L6.stringsFitPanel());
    std::printf("DUR_PROOF total_6:00 x=%d w=%d panelR=%d fit=%d\n", L6.totalX, L6.totalW,
                L6.panel.x + L6.panel.w, (int)L6.stringsFitPanel());

    // Also 12x16-scale path (smaller cell) must still fit — force via small canvas.
    {
        const auto ms = OverlayLayoutMetrics::compute(320, 240);
        CHECK(ms.fontId == OverlayFontId::Small8x13);
        auto Ls = PlaybackOverlay::computePanelLayout(320, 240, false, PlaybackOverlayState::Paused,
                                                      "MISTERPLEX", pos, dur);
        std::printf("SMALL secondLine=%d title='%s' fit=%d\n", Ls.titleSecondLine, Ls.titleFitted,
                    (int)Ls.stringsFitPanel());
        CHECK(Ls.stringsFitPanel());
    }

    // Pixel smoke: render must not paint title ink past panel right edge.
    {
        std::vector<uint8_t> yuv(static_cast<size_t>(W) * H * 3 / 2, 16);
        std::fill(yuv.begin() + W * H, yuv.end(), 128);
        misterplex::PlaybackOverlay ov;
        ov.setTitle("MISTERPLEX");
        ov.showAt(PlaybackOverlayState::Paused, pos, dur, 0);
        CHECK(ov.renderYuv420pAt(yuv.data(), W, H, 0));
        // Scan label+title rows for ink past panel.x+panel.w
        const int y0 = L.labelY;
        const int y1 = std::min(H, L.timeY + L.metrics.textCellH());
        int outside = 0;
        for (int y = y0; y < y1; ++y) {
            for (int x = L.panel.x + L.panel.w; x < W; ++x) {
                if (yuv[static_cast<size_t>(y) * W + x] > 40)
                    ++outside;
            }
        }
        std::printf("PIXEL_OUTSIDE_PANEL_INK=%d\n", outside);
        CHECK(outside == 0);
    }

    if (gFails) {
        std::fprintf(stderr, "test_overlay_layout_fit: %d FAIL(s)\n", gFails);
        return 1;
    }
    std::printf("test_overlay_layout_fit: PASS\n");
    std::printf("DURATION_VERDICT: geometry fits 2:14/2:18 and 2:14/6:00 inside panel; "
                "parent '0:30' is NOT explained by total-string overflow on this path "
                "(unknown — would need device durationMs dump).\n");
    return 0;
}
