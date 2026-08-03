// Host PLXC contract: pack/unpack + "no pixel bake when plane live".
#include "libmisterplex/plex_chrome_cmds.hpp"
#include "libmisterplex/playback_overlay.hpp"

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
    CHECK(cmds.size() <= 32u);
}

int main() {
    checkPackRoundtrip();
    checkNoPixelBakeWhenLive();
    checkStoppedHudHasBarAndState();
    if (fails) {
        std::fprintf(stderr, "test_plex_chrome_cmds: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "test_plex_chrome_cmds: PASS\n");
    return 0;
}
