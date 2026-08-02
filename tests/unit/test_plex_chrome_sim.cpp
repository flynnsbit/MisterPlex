// G2 host behavioral sim — plex_chrome integer NN vs bank-then-stretch.
// Red-before-green: bank path MUST fail edge metric; fabric path MUST pass
// at ≥2 HDMI geometries (640×480 and 1920×1080). No Quartus / no device.
//
// Metric: maximal ink run lengths must be multiples of fabric bodyScale
// (integer NN cells). 1080/480 = 2.25 makes bank-stretch runs irregular.

#include "libmisterplex/plex_chrome_sim.hpp"
#include "libmisterplex/mister_video_mode.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/playback_overlay.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdio>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

// Single solid '#' block — full 8×8 ink so cellH == 8*scale exactly on fabric path.
static void renderSolidBlockFabric(misterplex::plex_chrome_sim::Raster& r, int w, int h, int scale) {
    using namespace misterplex::plex_chrome_sim;
    Cmd cmds[2];
    cmds[0].op = Op::Glyph;
    cmds[0].x = static_cast<uint16_t>(w / 4);
    cmds[0].y = static_cast<uint16_t>(h / 2);
    cmds[0].code = static_cast<uint8_t>('#');
    cmds[0].rgba_r = cmds[0].rgba_g = cmds[0].rgba_b = 255;
    cmds[1].op = Op::End;
    (void)scale;
    renderFabric(r, w, h, cmds, 2);
}

static void checkFabricMode(int w, int h, int expectScale) {
    using namespace misterplex::plex_chrome_sim;
    CHECK(fabricBodyScale(h) == expectScale);
    CHECK(misterplex::computeOutputChromeLayout(w, h).bodyScale == expectScale);

    Raster r;
    renderSolidBlockFabric(r, w, h, expectScale);
    const EdgeStats st = measureEdgeRuns(r, expectScale);
    std::fprintf(stderr,
                 "FABRIC %dx%d scale=%d ink=%d hBad=%d/%d vBad=%d/%d bbox=%dx%d\n", w, h,
                 expectScale, st.inkPixels, st.hRunsNotMultipleOfScale, st.hRuns,
                 st.vRunsNotMultipleOfScale, st.vRuns, st.cellW, st.cellH);
    CHECK(st.inkPixels > 50);
    CHECK(st.hRuns > 0);
    CHECK(st.vRuns > 0);
    // Integer NN: every run is a multiple of scale
    CHECK(st.hRunsNotMultipleOfScale == 0);
    CHECK(st.vRunsNotMultipleOfScale == 0);
    // Solid 8×8 × scale → exact cell
    CHECK(st.cellH == kFontH * expectScale);
    CHECK(st.cellW == kFontW * expectScale);
    CHECK(st.minHRun >= expectScale);
    // Also: PAUSED list still paints with zero bad runs (semantic path)
    {
        const auto cmds = makePausedList(w, h);
        Raster r2;
        renderFabric(r2, w, h, cmds.data(), cmds.size());
        const EdgeStats st2 = measureEdgeRuns(r2, expectScale);
        CHECK(st2.inkPixels > 50);
        CHECK(st2.hRunsNotMultipleOfScale == 0);
        CHECK(st2.vRunsNotMultipleOfScale == 0);
    }
}

static void checkBankStretchFailsAt1080() {
    using namespace misterplex::plex_chrome_sim;
    // Product bank 624×480, bodyScale 2, then stretch to 1920×1080 (glass path).
    constexpr int bankW = 624, bankH = 480, bankScale = 2;
    constexpr int hdmiW = 1920, hdmiH = 1080;
    constexpr int fabricScale = 4; // what user wants at 1080p
    Raster r;
    renderBankThenStretch(r, bankW, bankH, bankScale, hdmiW, hdmiH, "#",
                          /*textXBank*/ 200, /*textYBank*/ 400);
    const EdgeStats st = measureEdgeRuns(r, fabricScale);
    std::fprintf(stderr,
                 "BANK-STRETCH %dx%d→%dx%d expectScale=%d ink=%d hBad=%d/%d vBad=%d/%d "
                 "bbox=%dx%d (fabric wants %dx%d)\n",
                 bankW, bankH, hdmiW, hdmiH, fabricScale, st.inkPixels,
                 st.hRunsNotMultipleOfScale, st.hRuns, st.vRunsNotMultipleOfScale, st.vRuns,
                 st.cellW, st.cellH, kFontW * fabricScale, kFontH * fabricScale);
    CHECK(st.inkPixels > 50);
    // Must FAIL sharpness against fabric scale-4 cells (user bug #2 mechanism).
    const bool badRuns = (st.hRunsNotMultipleOfScale > 0) || (st.vRunsNotMultipleOfScale > 0);
    const bool badSize =
        (st.cellH != kFontH * fabricScale) || (st.cellW != kFontW * fabricScale);
    CHECK(badRuns || badSize);
    // Pre-register: 1080/480 is not integer → irregular runs OR wrong cell vs 32×32
    CHECK(badRuns);
    CHECK(badSize);
}

// Mutation: if someone "fixes" the gate by only checking ink>0, this still fails
// when we force fractional scale path to look green incorrectly.
static void checkMutationEmptyIsNotPass() {
    using namespace misterplex::plex_chrome_sim;
    Raster empty;
    empty.clear(64, 64);
    const EdgeStats st = measureEdgeRuns(empty, 4);
    CHECK(st.inkPixels == 0);
    // Empty is NOT a pass for fabric — caller must require ink + zero bad runs.
    const bool wouldPassFabric = (st.inkPixels > 50) && (st.hRunsNotMultipleOfScale == 0);
    CHECK(!wouldPassFabric);
}

int main() {
    using namespace misterplex::plex_chrome_sim;

    // ABI offsets doorbell-relative — sim constants must match mailbox_abi_spec
    CHECK(kPlxcOffset == 0x130u);
    CHECK(kPlxoOffset == 0x138u);
    CHECK(kPlxcOffset == mailbox_abi::kPlxcOffset);
    CHECK(kPlxoOffset == mailbox_abi::kPlxoOffset);
    CHECK(kPlxcMagic == mailbox_abi::kPlxcMagic);
    CHECK(kPlxoMagic == mailbox_abi::kPlxoMagic);
    CHECK(mailbox_abi::frameStoreMailboxPhys(0x300FF000u, mailbox_abi::kPlxcOffset) ==
          0x300FF130u);

    std::fprintf(stderr, "=== RED: bank-then-stretch must fail fabric edge metric ===\n");
    checkBankStretchFailsAt1080();

    std::fprintf(stderr, "=== GREEN: fabric integer NN at ≥2 geometries ===\n");
    checkFabricMode(640, 480, /*scale*/ 2);
    checkFabricMode(1920, 1080, /*scale*/ 4);
    checkFabricMode(800, 600, /*scale*/ 2);
    checkFabricMode(320, 240, /*scale*/ 2);

    checkMutationEmptyIsNotPass();

    // Freeze: product bank 624×480 path metrics unchanged (c5382bee class / plane=0).
    // Fabric plane must not require changing bank authoring scale when chrome_hw=0.
    std::fprintf(stderr, "=== FREEZE: bank 624x480 plane0 metrics ===\n");
    {
        using namespace misterplex;
        const auto g = ddrFrameGeometryForFpgaPresent(320, 240);
        CHECK(g.coded_width.get() == 624);
        CHECK(g.coded_height.get() == 480);
        PlaybackOverlay ov;
        ov.showAt(PlaybackOverlayState::Paused, 12'000, 120'000, 0);
        CHECK(!ov.outputRasterLayout());
        const auto m = ov.activeLayoutMetrics(g.coded_width.get(), g.coded_height.get());
        CHECK(m.bodyScale == 2);
        CHECK(m.fontId == OverlayFontId::Hires24x32);
        // Glass criterion prereg cross-check: bank cellH vs fabric 1080 cellH
        const int bankCellH = 32 * m.bodyScale; // 24x32 font row cells
        const int fabCellH = 8 * fabricBodyScale(1080); // sim 8x8 * scale4
        CHECK(bankCellH == 64);
        CHECK(fabCellH == 32);
        // After stretch bank solid 8x8@2 → 49x36 ≠ fabric 32x32 (already RED above)
        std::fprintf(stderr, "FREEZE bankCellH=%d fab1080_sim8x8=%d (product 24x32@2 bank=64)\n",
                     bankCellH, fabCellH);
    }

    // Glass prereg dump (parent captures; host states expected numbers)
    std::fprintf(stderr,
                 "GLASS_PREREG 1080p: fabric # bbox=32x32 run%%4==0; "
                 "bank-stretch # bbox~49x36 hBad>0\n");

    // encodeCmdWord bit layout smoke (RTL pack)
    {
        using namespace misterplex::plex_chrome_sim;
        Cmd g;
        g.op = Op::Glyph;
        g.x = 100;
        g.y = 200;
        g.code = static_cast<uint8_t>('#');
        const uint64_t w = encodeCmdWord(g);
        CHECK((w & 0xffu) == 2u);
        CHECK(((w >> 8) & 0xffffu) == 100u);
        CHECK(((w >> 24) & 0xffffu) == 200u);
        CHECK(((w >> 40) & 0xffu) == static_cast<uint8_t>('#'));
    }

    if (fails) {
        std::fprintf(stderr, "test_plex_chrome_sim: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_plex_chrome_sim: PASS\n");
    return 0;
}
