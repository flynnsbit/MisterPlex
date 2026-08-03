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
    // idle early-out with no paint
    CHECK(src.find("idle fabric plane=1 skip ALL ARM paint") != std::string::npos);
    // Must not have "skip DDR" only (old half-offload) without ALL ARM paint
    CHECK(src.find("skip ALL ARM paint") != std::string::npos);
    // Progress path must NOT republish PLXC every N frames (state-change only).
    CHECK(src.find("publishPlxcHud(PlaybackOverlayState::Playing, tms, durationMs") == std::string::npos);
    CHECK(src.find("PLXC is state-change only") != std::string::npos);
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
    checkZeroPerPixelArmWhenLiveSource();
    checkStoppedHudHasBarAndState();
    check720pHudBudget();
    checkHudIsOutputNotCoded();
    checkCodedSizeRejectedForChrome();
    if (fails) {
        std::fprintf(stderr, "test_plex_chrome_cmds: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_plex_chrome_cmds: PASS\n");
    return 0;
}
