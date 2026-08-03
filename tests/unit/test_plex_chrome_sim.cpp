// G2 host behavioral sim — plex_chrome integer NN vs bank-then-stretch.
// Red-before-green: bank path MUST fail edge metric; fabric path MUST pass.
#include "libmisterplex/plex_chrome_sim.hpp"
#include "libmisterplex/plex_chrome_cmds.hpp"
#include "libmisterplex/mister_video_mode.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdio>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static void checkFabricSolidHash(int w, int h, int expectScale) {
    using namespace misterplex::plex_chrome_sim;
    CHECK(fabricBodyScale(h) == expectScale);
    CHECK(misterplex::computeOutputChromeLayout(w, h).bodyScale == expectScale);

    uint64_t cmds[2];
    cmds[0] = misterplex::plex_chrome_cmds::packGlyph(
        static_cast<uint16_t>(w / 4), static_cast<uint16_t>(h / 2), '#');
    cmds[1] = 0; // END
    Raster r;
    renderFabricWords(r, w, h, cmds, 2);
    const EdgeStats st = measureEdgeRuns(r, expectScale);
    std::fprintf(stderr, "FABRIC %dx%d scale=%d ink=%d hBad=%d/%d vBad=%d/%d bbox=%dx%d\n", w, h,
                 expectScale, st.inkPixels, st.hRunsNotMultipleOfScale, st.hRuns,
                 st.vRunsNotMultipleOfScale, st.vRuns, st.cellW, st.cellH);
    CHECK(st.inkPixels > 50);
    CHECK(st.hRunsNotMultipleOfScale == 0);
    CHECK(st.vRunsNotMultipleOfScale == 0);
    CHECK(st.cellH == kFontH * expectScale);
    CHECK(st.cellW == kFontW * expectScale);
}

static void checkBankStretchFailsAt1080() {
    using namespace misterplex::plex_chrome_sim;
    constexpr int bankW = 624, bankH = 480, bankScale = 2;
    constexpr int hdmiW = 1920, hdmiH = 1080;
    constexpr int fabricScale = 4;
    Raster r;
    renderBankThenStretch(r, bankW, bankH, bankScale, hdmiW, hdmiH, "#", 200, 400);
    const EdgeStats st = measureEdgeRuns(r, fabricScale);
    std::fprintf(stderr,
                 "BANK-STRETCH ink=%d hBad=%d/%d vBad=%d/%d bbox=%dx%d\n", st.inkPixels,
                 st.hRunsNotMultipleOfScale, st.hRuns, st.vRunsNotMultipleOfScale, st.vRuns,
                 st.cellW, st.cellH);
    CHECK(st.inkPixels > 50);
    const bool badRuns = (st.hRunsNotMultipleOfScale > 0) || (st.vRunsNotMultipleOfScale > 0);
    const bool badSize =
        (st.cellH != kFontH * fabricScale) || (st.cellW != kFontW * fabricScale);
    CHECK(badRuns || badSize);
    CHECK(badRuns);
}

static void checkHudCmdBudget() {
    using namespace misterplex::plex_chrome_cmds;
    BuildArgs a;
    a.outW = kTargetOutW;
    a.outH = kTargetOutH;
    a.state = misterplex::PlaybackOverlayState::Stopped;
    a.positionMs = 0;
    a.durationMs = 0;
    a.title = "BIG BUCK B";
    const auto cmds = buildPlaybackHud(a);
    std::fprintf(stderr, "HUD cmds=%zu max=%d hit=%d @%dx%d scale=%d\n", cmds.size(),
                 kMaxCmds, kHitScan, a.outW, a.outH, bodyScale(a.outH));
    CHECK(!cmds.empty());
    CHECK(cmds.size() <= static_cast<size_t>(kMaxCmds));
    CHECK(cmds.size() <= static_cast<size_t>(kHitScan));
    CHECK(bodyScale(720) == 3);
    // Must include STOPPED glyphs
    bool hasS = false;
    for (uint64_t w : cmds) {
        if ((w & 0xFF) == static_cast<uint8_t>(Op::Glyph) && ((w >> 40) & 0xFF) == 'S')
            hasS = true;
    }
    CHECK(hasS);
}

static void checkIdleFabric() {
    using namespace misterplex::plex_chrome_sim;
    Raster r;
    renderIdleFabric(r, 64, 64, /*logo*/ 0);
    int amber = 0, bg = 0;
    for (size_t i = 0; i < r.r.size(); ++i) {
        if (r.r[i] == 0xE5 && r.g[i] == 0xA0)
            ++amber;
        if (r.r[i] == 0x1F && r.g[i] == 0x23)
            ++bg;
    }
    std::fprintf(stderr, "IDLE amber=%d bg=%d\n", amber, bg);
    CHECK(amber > 10);
    CHECK(bg > 100);
    // Black mode paints zero amber
    renderIdleFabric(r, 64, 64, 1);
    amber = 0;
    for (size_t i = 0; i < r.r.size(); ++i)
        if (r.r[i] | r.g[i] | r.b[i])
            ++amber;
    CHECK(amber == 0);
}

static void checkPlaneLiveGate() {
    using namespace misterplex::plex_chrome_cmds;
    CHECK(!chromePlaneLive(true, false)); // conf alone must not blank chrome
    CHECK(!chromePlaneLive(false, true));
    CHECK(chromePlaneLive(true, true));
}

static void checkMutationEmptyNotPass() {
    using namespace misterplex::plex_chrome_sim;
    Raster empty;
    empty.clear(64, 64);
    const EdgeStats st = measureEdgeRuns(empty, 4);
    CHECK(st.inkPixels == 0);
    CHECK(!((st.inkPixels > 50) && (st.hRunsNotMultipleOfScale == 0)));
}

int main() {
    using namespace misterplex::plex_chrome_sim;
    CHECK(kPlxcOffset == 0x130u);
    CHECK(kPlxoOffset == 0x138u);
    CHECK(kPlxcMagic == mailbox_abi::kPlxcMagic);
    CHECK(mailbox_abi::frameStoreMailboxPhys(0x300FF000u, mailbox_abi::kPlxcOffset) ==
          0x300FF130u);
    CHECK(mailbox_abi::kPlxlOffset == 0x140u);

    std::fprintf(stderr, "=== RED: bank-then-stretch ===\n");
    checkBankStretchFailsAt1080();
    std::fprintf(stderr, "=== GREEN: fabric NN ===\n");
    checkFabricSolidHash(640, 480, 2);
    checkFabricSolidHash(1920, 1080, 4);
    checkFabricSolidHash(320, 240, 2);
    checkHudCmdBudget();
    checkIdleFabric();
    checkPlaneLiveGate();
    checkMutationEmptyNotPass();

    if (fails) {
        std::fprintf(stderr, "test_plex_chrome_sim: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_plex_chrome_sim: PASS\n");
    return 0;
}
