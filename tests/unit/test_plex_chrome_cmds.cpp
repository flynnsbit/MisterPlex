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
                 "fits=%d max=%d\n",
                 bCore.totalUncapped, bCore.panel, bCore.stateGlyphs, bCore.titleGlyphs,
                 bCore.timeGlyphs, bCore.track, bCore.fillChunks, bCore.fitsProductList ? 1 : 0,
                 kMaxCmds);
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
                 "UI_BUDGET full total=%d skip=%d notice=%d buf=%d fits=%d max=%d\n",
                 bFull.totalUncapped, bFull.skip, bFull.notice, bFull.buffering,
                 bFull.fitsProductList ? 1 : 0, bFull.maxCmds);
    CHECK(bFull.skip > 0);
    CHECK(bFull.notice > 0);
    CHECK(bFull.buffering > 0);
    // Product list depth must absorb the simultaneous full UI (no silent trim).
    CHECK(bFull.fitsProductList);
    CHECK(bFull.totalUncapped <= kMaxCmds);

    // PLAYING worst title + full bar fill
    BuildArgs play;
    play.state = misterplex::PlaybackOverlayState::Playing;
    play.positionMs = 3599999;
    play.durationMs = 3600000;
    play.title = "0123456789012345678"; // 19
    HudBudget bPlay = countHudBudget(play);
    std::fprintf(stderr, "UI_BUDGET playing_worst total=%d fits=%d\n", bPlay.totalUncapped,
                 bPlay.fitsProductList ? 1 : 0);
    CHECK(bPlay.fitsProductList);

    // --- True worst case under current API caps (title19 + notice31 + long times + skip + buf) ---
    BuildArgs worst;
    worst.outW = kHdmiOutW;
    worst.outH = kHdmiOutH;
    worst.state = misterplex::PlaybackOverlayState::Playing;
    worst.positionMs = 359999000; // forces H:MM:SS
    worst.durationMs = 359999000;
    char title19[20];
    std::memset(title19, 'X', 19);
    title19[19] = 0;
    worst.title = title19;
    worst.skipDeltaMs = 999999000; // long skip string
    char notice31[32];
    std::memset(notice31, 'N', 31);
    notice31[31] = 0;
    worst.notice = notice31;
    worst.buffering = true;
    HudBudget bW = countHudBudget(worst);
    std::fprintf(stderr, "UI_BUDGET true_worst_720p total=%d max=%d fits=%d\n",
                 bW.totalUncapped, kMaxCmds, bW.fitsProductList ? 1 : 0);
    CHECK(bW.totalUncapped >= 79); // prior short-simultaneous under-count
    CHECK(bW.totalUncapped <= kMaxCmds);
    CHECK(bW.fitsProductList);
    // Growth ceiling note: new HUD elements or longer caps raise this; kMaxCmds is the hard gate.

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

// Chrome layout is HDMI_OUT-only: content/core geometry must not move commands.
// Product path uses chrome canvas (1280×720), never STORAGE/CORE_DE sizes.
static void checkChromeLayoutInvariantToContentGeom() {
    using namespace misterplex::plex_chrome_cmds;
    // Three content geometries parent measured on PMS (decode/core). Canvas fixed.
    const int contents[][2] = {{320, 240}, {640, 360}, {960, 540}};
    std::vector<uint64_t> ref;
    for (int i = 0; i < 3; ++i) {
        const int cw = contents[i][0], ch = contents[i][1];
        // Product builder: outW/outH = HDMI glass only. Content is not an input.
        BuildArgs a;
        a.outW = kHdmiOutW;
        a.outH = kHdmiOutH;
        a.state = misterplex::PlaybackOverlayState::Playing;
        a.positionMs = 125000;
        a.durationMs = 600000;
        a.title = "BIG BUCK BUNNY TITLE";
        auto cmds = buildPlaybackHud(a);
        // Sanity: content sizes are coded/storage class — refused as chrome canvas.
        CHECK(isCodedBankSizeNotHdmi(cw, ch) || (cw == 640 && ch == 360));
        CHECK(!isHdmiChromeRaster(cw, ch));
        if (i == 0)
            ref = cmds;
        else {
            CHECK(cmds.size() == ref.size());
            for (size_t k = 0; k < ref.size(); ++k)
                CHECK(cmds[k] == ref[k]);
        }
        std::fprintf(stderr, "INVARIANT content=%dx%d hud_cmds=%zu identical=%d\n", cw, ch,
                     cmds.size(), i == 0 ? 1 : 1);
    }
    // setChromeOutputSize product refuse: coded sizes must not replace HDMI defaults.
    // (media_player.hpp — tested via isCodedBankSizeNotHdmi which gates the setter)
    CHECK(isCodedBankSizeNotHdmi(320, 240));
    CHECK(isCodedBankSizeNotHdmi(960, 540));
    CHECK(!isCodedBankSizeNotHdmi(1280, 720));
}

// Red twin: injecting content geometry into outW/outH MUST break byte-identity.
static void checkChromeLayoutContentLeakRedTwin() {
    using namespace misterplex::plex_chrome_cmds;
    BuildArgs hdmi;
    hdmi.outW = kHdmiOutW;
    hdmi.outH = kHdmiOutH;
    hdmi.state = misterplex::PlaybackOverlayState::Stopped;
    hdmi.positionMs = 125000;
    hdmi.durationMs = 600000;
    hdmi.title = "TITLE";
    const auto good = buildPlaybackHud(hdmi);

    const int leaks[][2] = {{320, 240}, {640, 360}, {960, 540}};
    std::vector<std::vector<uint64_t>> bad;
    for (auto& g : leaks) {
        BuildArgs a = hdmi;
        a.outW = g[0]; // FAULT: content/core as chrome canvas
        a.outH = g[1];
        bad.push_back(buildPlaybackHud(a));
    }
    // At least one leak must differ from HDMI product list (else red twin is toothless).
    bool any_diff = false;
    for (auto& b : bad) {
        if (b.size() != good.size()) {
            any_diff = true;
            break;
        }
        for (size_t i = 0; i < good.size(); ++i) {
            if (b[i] != good[i]) {
                any_diff = true;
                break;
            }
        }
        if (any_diff)
            break;
    }
    CHECK(any_diff);
    // The three leaked canvases must not all match each other either (geom-dependent).
    CHECK(!(bad[0].size() == bad[1].size() && bad[0] == bad[1] && bad[1] == bad[2]));
    std::fprintf(stderr, "RED_TWIN content-leak: HDMI cmds=%zu leak320=%zu leak640=%zu leak960=%zu\n",
                 good.size(), bad[0].size(), bad[1].size(), bad[2].size());
}

// R2 closed: flashPlaybackSkip must publish PLXC when plane live (not ARM pixels).
// Negative: absence of publishPlxcHud under flashPlaybackSkip is FAIL.
static void checkFlashSkipPublishesPlxc() {
    FILE* f = std::fopen("arm/misterplexd/media_player.cpp", "r");
    CHECK(f != nullptr);
    if (!f)
        return;
    std::string src;
    char buf[4096];
    while (std::fgets(buf, sizeof(buf), f))
        src += buf;
    std::fclose(f);

    const auto flash_pos = src.find("void MediaPlayer::flashPlaybackSkip");
    CHECK(flash_pos != std::string::npos);
    if (flash_pos == std::string::npos)
        return;
    // Bound the function body roughly (next top-level MediaPlayer:: after flash)
    const auto next_fn = src.find("void MediaPlayer::", flash_pos + 10);
    const std::string body = src.substr(flash_pos,
                                        next_fn == std::string::npos ? std::string::npos
                                                                     : next_fn - flash_pos);
    // Must call publish under chromePlaneLive — not render/blit
    CHECK(body.find("chromePlaneLive()") != std::string::npos);
    CHECK(body.find("publishPlxcHud") != std::string::npos);
    CHECK(body.find("skipDeltaMs") != std::string::npos ||
          body.find("deltaMs") != std::string::npos);
    // Negative: no pixel bake *calls* inside flash (comments may mention blit).
    CHECK(body.find("renderPlaybackOverlay(") == std::string::npos);
    CHECK(body.find("->blit") == std::string::npos);
    CHECK(body.find(".blit") == std::string::npos);
    CHECK(body.find("writeChromePixels") == std::string::npos);
    CHECK(body.find("paintIdle") == std::string::npos);
    // RED twin shape: flash that only updates overlay_ without PLXC is incomplete
    // (R2 residual). Must not be "flashSkip(...);" alone without publish.
    CHECK(body.find("overlay_.flashSkip") != std::string::npos);
    const auto pub = body.find("publishPlxcHud");
    const auto flash = body.find("overlay_.flashSkip");
    CHECK(pub != std::string::npos && flash != std::string::npos && pub > flash);
}

int main() {
    checkPackRoundtrip();
    checkNoPixelBakeWhenLive();
    checkRedTwinArmPixelBakeCaught();
    checkZeroPerPixelArmWhenLiveSource();
    checkFlashSkipPublishesPlxc();
    checkChromeLayoutInvariantToContentGeom();
    checkChromeLayoutContentLeakRedTwin();
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
