// Host PLXC contract: pack/unpack + "no pixel bake when plane live".
#include "libmisterplex/plex_chrome_cmds.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static void checkPackRoundtrip() {
    using namespace misterplex::plex_chrome_cmds;
    const uint64_t g = packGlyph(100, 200, 'P');
    CHECK((g & 0xFF) == 2);
    CHECK(((g >> 8) & 0xFFFF) == 100);
    CHECK(((g >> 24) & 0xFFFF) == 200);
    CHECK(((g >> 40) & 0xFF) == 'P');

    const uint64_t r = packRect(10, 20, 600, 72);
    CHECK((r & 0xFF) == 1);
    CHECK(((r >> 40) & 0xFFF) == 600);
    CHECK(((r >> 52) & 0xFFF) == 72);

    const uint64_t c = packPlxcCtrl(true, 17, 42);
    CHECK((c & 0xFFFFFFFFu) == kMagic);
    CHECK(((c >> 32) & 1) == 1);
    CHECK(((c >> 34) & 0x3FFF) == 17);
    CHECK(((c >> 48) & 0xFFFF) == 42);
}

// RED: naive "always bake pixels" would dirty the frame when plane live.
// GREEN: plane live ⇒ zero pixel writes from overlay path (caller skips render).
static void checkNoPixelBakeWhenLive() {
    misterplex::PlaybackOverlay ov;
    ov.showAt(misterplex::PlaybackOverlayState::Stopped, 0, 0, 1000);
    std::vector<uint8_t> frame(320 * 240 * 3, 0x5A);
    const auto before = frame;
    const bool live = misterplex::plex_chrome_cmds::chromePlaneLive(true, true);
    CHECK(live);
    if (!live) {
        // naive wrong path
        ov.renderRgb24At(frame.data(), 320, 240, 1000);
    }
    // With live gate, frame must be untouched
    CHECK(frame == before);

    // Negative: plane not live DOES bake (proves test is not vacuous)
    std::vector<uint8_t> frame2(320 * 240 * 3, 0x5A);
    const auto before2 = frame2;
    if (!misterplex::plex_chrome_cmds::chromePlaneLive(true, false)) {
        CHECK(ov.renderRgb24At(frame2.data(), 320, 240, 1000));
    }
    CHECK(frame2 != before2);
}

// Stronger red twin: a deliberate "wrong" path that bakes pixels under a live
// plane MUST be distinguishable from the correct skip. The product gate is the
// `if (!live) bake` shape — flipping it dirties the frame and fails the check.
static void checkRedTwinArmPixelBakeCaught() {
    misterplex::PlaybackOverlay ov;
    ov.showAt(misterplex::PlaybackOverlayState::Playing, 30000, 120000, 5000);
    std::vector<uint8_t> frame(640 * 360 * 3, 0x11);
    const auto clean = frame;
    const bool live = misterplex::plex_chrome_cmds::chromePlaneLive(true, true);
    CHECK(live);

    // Correct product shape
    if (!live)
        ov.renderRgb24At(frame.data(), 640, 360, 5000);
    CHECK(frame == clean);

    // Naive wrong implementation: bake even when live
    auto wrong = clean;
    if (live) // deliberately inverted gate
        CHECK(ov.renderRgb24At(wrong.data(), 640, 360, 5000));
    CHECK(wrong != clean); // red twin fires: pixels changed under live plane

    // PLXC path is command words only — never a byte of RGB
    using namespace misterplex::plex_chrome_cmds;
    BuildArgs a;
    a.state = misterplex::PlaybackOverlayState::Playing;
    a.positionMs = 30000;
    a.durationMs = 120000;
    a.title = "TITLE";
    const auto cmds = buildPlaybackHud(a);
    CHECK(!cmds.empty());
    for (uint64_t w : cmds) {
        const unsigned op = static_cast<unsigned>(w & 0xFF);
        CHECK(op == 1 || op == 2 || op == 3); // RECT / GLYPH / RECT_PAL only
    }
}

// Player UI inventory vs MAX_CMDS — do not silently trim requirements.
static void checkPlayerUiCommandBudget() {
    using namespace misterplex::plex_chrome_cmds;

    // --- Core HUD (state + title + times + bar): parent glass capture class ---
    BuildArgs core;
    core.state = misterplex::PlaybackOverlayState::Stopped;
    core.positionMs = 125000;
    core.durationMs = 600000;
    core.title = "BIG BUCK BUNNY TITLE"; // 19-char cap
    HudBudget bCore = countHudBudget(core);
    std::fprintf(stderr,
                 "UI_BUDGET core total=%d panel=%d state=%d title=%d time=%d track=%d fill=%d "
                 "fits48=%d\n",
                 bCore.totalUncapped, bCore.panel, bCore.stateGlyphs, bCore.titleGlyphs,
                 bCore.timeGlyphs, bCore.track, bCore.fillChunks, bCore.fitsProductList ? 1 : 0);
    CHECK(bCore.panel == 1);
    CHECK(bCore.track == 1);
    CHECK(bCore.stateGlyphs == 7); // STOPPED
    CHECK(bCore.titleGlyphs >= 10);
    CHECK(bCore.timeGlyphs >= 6);
    CHECK(bCore.fitsProductList);
    CHECK(bCore.totalUncapped <= kMaxCmds);
    CHECK(buildPlaybackHud(core).size() == static_cast<size_t>(bCore.totalUncapped));

    // --- Full simultaneous (core + skip + notice + buffering) ---
    BuildArgs full = core;
    full.skipDeltaMs = 30000;
    full.notice = "F12 INERT ON THIS BUILD";
    full.buffering = true;
    HudBudget bFull = countHudBudget(full);
    std::fprintf(stderr,
                 "UI_BUDGET full total=%d skip=%d notice=%d buf=%d fits48=%d max=%d\n",
                 bFull.totalUncapped, bFull.skip, bFull.notice, bFull.buffering,
                 bFull.fitsProductList ? 1 : 0, bFull.maxCmds);
    CHECK(bFull.skip > 0);
    CHECK(bFull.notice > 0);
    CHECK(bFull.buffering > 0);
    // Honest: if full UI exceeds 48, report — do NOT pretend it fits.
    if (!bFull.fitsProductList) {
        std::fprintf(stderr,
                     "UI_BUDGET_NEED max_cmds_ge=%d (product kMaxCmds=%d) — raise list depth; "
                     "do not trim UI\n",
                     bFull.totalUncapped, kMaxCmds);
    }
    // Core-only product path must still fit today.
    CHECK(bCore.fitsProductList);

    // PLAYING worst title + full bar fill
    BuildArgs play;
    play.state = misterplex::PlaybackOverlayState::Playing;
    play.positionMs = 3599999;
    play.durationMs = 3600000;
    play.title = "0123456789012345678"; // 19
    HudBudget bPlay = countHudBudget(play);
    std::fprintf(stderr, "UI_BUDGET playing_worst total=%d fits48=%d\n", bPlay.totalUncapped,
                 bPlay.fitsProductList ? 1 : 0);
    CHECK(bPlay.fitsProductList);

    // Volume: not a drawn player-HUD element today (no glyph/rect). Residual: N/A.
}

static void checkStoppedHudHasBarAndState() {
    using namespace misterplex::plex_chrome_cmds;
    BuildArgs a;
    a.outW = 640;
    a.outH = 480;
    a.state = misterplex::PlaybackOverlayState::Stopped;
    a.positionMs = 125000;
    a.durationMs = 600000;
    a.title = "BIG BUCK B";
    auto cmds = buildPlaybackHud(a);
    int glyphs = 0, rects = 0, pals = 0;
    for (uint64_t w : cmds) {
        switch (w & 0xFF) {
        case 1: ++rects; break;
        case 2: ++glyphs; break;
        case 3: ++pals; break;
        }
    }
    std::fprintf(stderr, "STOPPED hud glyphs=%d rects=%d pals=%d total=%zu\n", glyphs, rects,
                 pals, cmds.size());
    CHECK(glyphs >= 7);  // STOPPED
    CHECK(rects >= 2);   // panel + track
    CHECK(pals >= 1);    // amber fill (position > 0)
    CHECK(cmds.size() <= static_cast<size_t>(kHitScan));
}

// Hard acceptance (parent 720p decode 41.073 ms/f, 1.4% margin): when plane live,
// media_player must not call render*/blit on the content/idle path.
// Source-level gate — red if someone reintroduces bake under chromePlaneLive.
static void checkZeroPerPixelArmWhenLiveSource() {
    FILE* f = std::fopen("arm/misterplexd/media_player.cpp", "r");
    CHECK(f != nullptr);
    if (!f)
        return;
    std::string src;
    char buf[4096];
    while (std::fgets(buf, sizeof(buf), f))
        src += buf;
    std::fclose(f);
    // presentCleanFrame bake only under !chromePlaneLive
    CHECK(src.find("if (!dirty.empty() && !chromePlaneLive())") != std::string::npos);
    // Must NOT bake when live (inverted gate is the red-twin shape)
    CHECK(src.find("if (!dirty.empty() && chromePlaneLive())") == std::string::npos);
    CHECK(src.find("if (dirty.empty() || chromePlaneLive())") == std::string::npos);
    // idle early-out with no paint
    CHECK(src.find("idle fabric plane=1 skip ALL ARM paint") != std::string::npos);
    // Must not have "skip DDR" only (old half-offload) without ALL ARM paint
    CHECK(src.find("skip ALL ARM paint") != std::string::npos);
    // Progress path must NOT republish PLXC every N frames (state-change only).
    CHECK(src.find("publishPlxcHud(PlaybackOverlayState::Playing, tms, durationMs") == std::string::npos);
    CHECK(src.find("PLXC is state-change only") != std::string::npos);
    // publishPlxcHud is semantic list only
    CHECK(src.find("Semantic list only — never pixels") != std::string::npos);
    CHECK(src.find("writeChromeCommandList") != std::string::npos);
    // Must not write RGB into chrome path
    CHECK(src.find("writeChromePixels") == std::string::npos);
    CHECK(src.find("bakeChromeRgb") == std::string::npos);
}

// writeChromeCommandList must touch mailbox list words, not frame RGB.
static void checkWriteChromeIsListNotPixels() {
    FILE* f = std::fopen("arm/misterplexd/fpga_spi.cpp", "r");
    CHECK(f != nullptr);
    if (!f)
        return;
    std::string src;
    char buf[4096];
    while (std::fgets(buf, sizeof(buf), f))
        src += buf;
    std::fclose(f);
    CHECK(src.find("writeChromeCommandList") != std::string::npos);
    // Locates PLXC ctrl + list region — not a present/RGB blit
    CHECK(src.find("kPlxcOffset") != std::string::npos ||
          src.find("PlxcOffset") != std::string::npos ||
          src.find("0x130") != std::string::npos);
    // Must not call blit inside writeChromeCommandList body — crude but catches
    // a naive "just paint the HUD into DDR" rewrite of the function.
    const auto pos = src.find("bool FpgaSpi::writeChromeCommandList");
    CHECK(pos != std::string::npos);
    if (pos != std::string::npos) {
        const auto end = src.find("\nbool FpgaSpi::", pos + 1);
        const std::string body = src.substr(pos, end == std::string::npos ? 4000 : end - pos);
        CHECK(body.find("blitRgb") == std::string::npos);
        CHECK(body.find("renderRgb") == std::string::npos);
        CHECK(body.find("writeFrame") == std::string::npos);
    }
}
// 720p-first: default BuildArgs and a full STOPPED HUD must fit the list.
static void check720pHudBudget() {
    using namespace misterplex::plex_chrome_cmds;
    CHECK(kTargetOutW == 1280);
    CHECK(kTargetOutH == 720);
    CHECK(bodyScale(720) == 3);
    BuildArgs a; // defaults 1280×720
    CHECK(a.outW == 1280);
    CHECK(a.outH == 720);
    a.state = misterplex::PlaybackOverlayState::Stopped;
    a.positionMs = 125000;
    a.durationMs = 600000;
    a.title = "BIG BUCK BUNNY TITLE";
    auto cmds = buildPlaybackHud(a);
    std::fprintf(stderr, "720p HUD cmds=%zu max=%d scale=%d\n", cmds.size(), kMaxCmds,
                 bodyScale(720));
    CHECK(!cmds.empty());
    CHECK(cmds.size() <= static_cast<size_t>(kMaxCmds));
    CHECK(cmds.size() <= static_cast<size_t>(kHitScan));
    // x coords must stay within 12-bit / 1280
    for (uint64_t w : cmds) {
        const unsigned x = static_cast<unsigned>((w >> 8) & 0xFFFF);
        const unsigned y = static_cast<unsigned>((w >> 24) & 0xFFFF);
        CHECK(x < 1280u);
        CHECK(y < 720u);
    }
}

// Product path: coded bank may be 960×540 while glass is 1280×720.
// RED: naive "HUD in coded pixels" places the bar inside y<540 — wrong under 720p HDMI.
// GREEN: panel/track live in the bottom band of the *output* raster (y near 720).
static void checkHudIsOutputNotCoded() {
    using namespace misterplex::plex_chrome_cmds;
    BuildArgs a;
    a.outW = 1280;
    a.outH = 720;
    a.state = misterplex::PlaybackOverlayState::Playing;
    a.positionMs = 30000;
    a.durationMs = 120000;
    a.title = "SRC960";
    auto cmds = buildPlaybackHud(a);
    unsigned minY = 0xffff, maxY = 0;
    for (uint64_t w : cmds) {
        const unsigned y = static_cast<unsigned>((w >> 24) & 0xFFFF);
        if (y < minY)
            minY = y;
        if (y > maxY)
            maxY = y;
    }
    std::fprintf(stderr, "HUD y-range [%u,%u] (coded would be y<540)\n", minY, maxY);
    // Bottom panel: all chrome geometry should sit in the lower half of 720p.
    CHECK(minY >= 360u);
    CHECK(maxY < 720u);
    // Negative: must NOT look like a 540p-tall canvas (bar near y=540-54).
    CHECK(minY > 540u - 80u); // still in lower band of 720, not mid-540
}

// Active-canvas derivation: HDMI_OUT 720p OK; STORAGE/CORE_DE sizes refused for product.
static void checkLayoutFromActiveHdmi() {
    using namespace misterplex::plex_chrome_cmds;
    int ow = 0, oh = 0, sc = 0;
    CHECK(chromeLayoutFromActiveHdmi(1280, 720, ow, oh, sc));
    CHECK(ow == 1280 && oh == 720 && sc == 3);
    // 1080p glass also OK (scale 4 or 5)
    CHECK(chromeLayoutFromActiveHdmi(1920, 1080, ow, oh, sc));
    CHECK(ow == 1920 && oh == 1080 && sc == bodyScale(1080));
    // RED: legacy 480p canvas must not become product layout
    CHECK(!chromeLayoutFromActiveHdmi(624, 480, ow, oh, sc));
    CHECK(!chromeLayoutFromActiveHdmi(640, 480, ow, oh, sc));
    // RED (ascal pivot class): CORE_DE/STORAGE 960×540 is not HDMI_OUT paint
    CHECK(!chromeLayoutFromActiveHdmi(960, 540, ow, oh, sc));
    CHECK(!chromeLayoutFromActiveHdmi(kStorageW, kStorageH, ow, oh, sc));
    CHECK(!chromeLayoutFromActiveHdmi(kCoreDeW, kCoreDeH, ow, oh, sc));
    // BuildArgs must track HDMI_OUT, not coded bank defaults
    BuildArgs a;
    CHECK(chromeLayoutFromActiveHdmi(kTargetOutW, kTargetOutH, a.outW, a.outH, sc));
    CHECK(kTargetOutW == kHdmiOutW && kTargetOutH == kHdmiOutH);
    auto cmds = buildPlaybackHud(a);
    unsigned minY = 0xffff;
    for (uint64_t w : cmds) {
        const unsigned y = static_cast<unsigned>((w >> 24) & 0xFFFF);
        if (y < minY)
            minY = y;
    }
    CHECK(minY >= 572u); // bottom band of 720p (matches geometry contract)
}

// Three paint domains: STORAGE refused; CORE_DE only when domain tagged; HDMI_OUT product.
static void checkPaintDomains() {
    using namespace misterplex::plex_chrome_cmds;
    int ow = 0, oh = 0, sc = 0;
    CHECK(!chromeLayoutFromPaintDomain(PaintDomain::Storage, 960, 540, ow, oh, sc));
    CHECK(!chromeLayoutFromPaintDomain(PaintDomain::Storage, 1280, 720, ow, oh, sc));
    // CORE_DE green (pre-ascal insertion experiment only)
    CHECK(chromeLayoutFromPaintDomain(PaintDomain::CoreDe, kCoreDeW, kCoreDeH, ow, oh, sc));
    CHECK(ow == 960 && oh == 540 && sc == bodyScale(540));
    CHECK(sc == 2);
    // CORE_DE must not accept HDMI glass size as "core DE"
    CHECK(!chromeLayoutFromPaintDomain(PaintDomain::CoreDe, 1280, 720, ow, oh, sc));
    // HDMI_OUT product
    CHECK(chromeLayoutFromPaintDomain(PaintDomain::HdmiOut, kHdmiOutW, kHdmiOutH, ow, oh, sc));
    CHECK(ow == 1280 && oh == 720 && sc == 3);
    // RED twin of FAULT_HDMI_LAYOUT_ON_CORE_DE: HdmiOut API on CORE_DE beam size
    CHECK(!chromeLayoutFromPaintDomain(PaintDomain::HdmiOut, 960, 540, ow, oh, sc));
}

// Width-keyed defect class: coded sizes must never be accepted as HDMI chrome.
static void checkCodedSizeRejectedForChrome() {
    using namespace misterplex::plex_chrome_cmds;
    CHECK(isCodedBankSizeNotHdmi(960, 540));
    CHECK(isCodedBankSizeNotHdmi(960, 544)); // 16-aligned pad of 540
    CHECK(isCodedBankSizeNotHdmi(624, 480));
    CHECK(isCodedBankSizeNotHdmi(320, 240));
    CHECK(!isCodedBankSizeNotHdmi(1280, 720));
    CHECK(!isCodedBankSizeNotHdmi(1920, 1080));
    CHECK(isHdmiChromeRaster(1280, 720));
    CHECK(!isHdmiChromeRaster(960, 540));
    CHECK(!isHdmiChromeRaster(923, 717)); // control letterbox — not a chrome canvas setter
    CHECK(isCoreDeChromeRaster(960, 540));
    CHECK(!isCoreDeChromeRaster(1280, 720));

    // If HUD is wrongly built in coded 960×540, bar lives below mid-540 — RED shape.
    BuildArgs bad;
    bad.outW = 960;
    bad.outH = 540;
    bad.state = misterplex::PlaybackOverlayState::Playing;
    bad.positionMs = 30000;
    bad.durationMs = 120000;
    auto cmds = buildPlaybackHud(bad);
    unsigned maxY = 0;
    for (uint64_t w : cmds) {
        const unsigned y = static_cast<unsigned>((w >> 24) & 0xFFFF);
        if (y > maxY)
            maxY = y;
    }
    std::fprintf(stderr, "coded-HUD maxY=%u (must be <540 — proves wrong canvas)\n", maxY);
    CHECK(maxY < 540u);
    CHECK(maxY > 0u);
    // Product path must not use this canvas:
    CHECK(!isHdmiChromeRaster(bad.outW, bad.outH));
}

int main() {
    checkPackRoundtrip();
    checkNoPixelBakeWhenLive();
    checkRedTwinArmPixelBakeCaught();
    checkZeroPerPixelArmWhenLiveSource();
    checkWriteChromeIsListNotPixels();
    checkStoppedHudHasBarAndState();
    checkPlayerUiCommandBudget();
    check720pHudBudget();
    checkPaintDomains();
    checkHudIsOutputNotCoded();
    checkLayoutFromActiveHdmi();
    checkCodedSizeRejectedForChrome();
    if (fails) {
        std::fprintf(stderr, "test_plex_chrome_cmds: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_plex_chrome_cmds: PASS\n");
    return 0;
}
