// Native chrome plane paint @ OUTPUT raster (not F1 bank).
#include "libmisterplex/chrome_plane.hpp"

#include <cstdio>
#include <cstdint>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static int countNonKey(const uint8_t* rgb565, int w, int h) {
    const auto* px = reinterpret_cast<const uint16_t*>(rgb565);
    int n = 0;
    const size_t N = static_cast<size_t>(w) * static_cast<size_t>(h);
    for (size_t i = 0; i < N; ++i) {
        if (px[i] != misterplex::kChromePlaneColorKey)
            ++n;
    }
    return n;
}

static void checkMode(int outW, int outH, int wantScale, bool wantLarge) {
    using namespace misterplex;
    PlaybackOverlay ov;
    ov.showAt(PlaybackOverlayState::Paused, 12'000, 120'000, /*now*/ 0);
    std::vector<uint8_t> buf(static_cast<size_t>(outW) * static_cast<size_t>(outH) * 2u);
    ChromePlanePaintResult meta;
    CHECK(paintChromePlaneRgb565(ov, buf.data(), outW, outH, &meta));
    CHECK(meta.ok);
    CHECK(meta.bodyScale == wantScale);
    CHECK(meta.useLargeFont == wantLarge);
    CHECK(meta.advancePx == meta.bodyScale * (wantLarge ? 13 : 9));
    CHECK(meta.panel.w > 0 && meta.panel.h > 0);
    CHECK(meta.panel.x >= 0 && meta.panel.y >= 0);
    CHECK(meta.panel.x + meta.panel.w <= outW);
    CHECK(meta.panel.y + meta.panel.h <= outH);
    // Panel sits in lower third-ish
    CHECK(meta.panel.y > outH / 2);
    const int ink = countNonKey(buf.data(), outW, outH);
    CHECK(ink > 100);
    // Bank path must still be independent: default layout not stuck on
    CHECK(!ov.outputRasterLayout());

    // Band extract smaller than full frame at 1080p+
    if (outH >= 480) {
        std::vector<uint8_t> band;
        int y0 = -1;
        ChromePlanePaintResult bm;
        CHECK(paintChromePlaneBandRgb565(ov, band, outW, outH, &y0, &bm));
        CHECK(y0 >= 0 && y0 < outH);
        CHECK(band.size() < buf.size());
        CHECK(band.size() == bm.bytes);
    }
}

int main() {
    using namespace misterplex;

    // User-named modes + device daily driver
    // Scales match G0 / computeOutputChromeLayout (half-to-even round H/240).
    checkMode(1920, 1440, /*scale*/ 6, /*large*/ true);
    checkMode(1920, 1080, 4, true);
    checkMode(800, 600, 2, true);
    checkMode(640, 480, 2, true);
    checkMode(320, 240, 2, false);

    // F1 bank path unchanged: 624×480 → scale 2 large font, NOT output scale 6
    {
        PlaybackOverlay ov;
        ov.showAt(PlaybackOverlayState::Paused, 0, 60'000, 0);
        CHECK(!ov.outputRasterLayout());
        const auto m = ov.activeLayoutMetrics(624, 480);
        CHECK(m.bodyScale == 2);
        CHECK(m.fontId == OverlayFontId::Hires24x32);
        const auto bank = OverlayLayoutMetrics::compute(624, 480);
        const auto out = OverlayLayoutMetrics::fromOutputLayout(1920, 1440);
        CHECK(bank.bodyScale == 2);
        CHECK(out.bodyScale == 6);
        CHECK(out.glyphAdvance == 13);
    }

    // Fail closed: conf without HW must not go live
    CHECK(!chromePlaneLiveAllowed(/*conf*/ true, /*hw*/ false));
    CHECK(!chromePlaneLiveAllowed(false, true));
    CHECK(chromePlaneLiveAllowed(true, true));

    if (fails) {
        std::fprintf(stderr, "test_chrome_plane_paint: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_chrome_plane_paint: OK\n");
    return 0;
}
