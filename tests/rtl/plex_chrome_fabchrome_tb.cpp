// Red-before-green: FAB_CHROME demo STOPPED HUD + magenta signature.
// RED (demo off): pure video green field, no magenta, no panel.
// GREEN (demo+sig): magenta TR/BL, white STOPPED glyphs, amber bar, video elsewhere.

#include "Vplex_chrome_fabchrome_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_chrome_fabchrome_tb* t) {
    t->clk = 0;
    t->eval();
    ++main_time;
    t->clk = 1;
    t->eval();
    ++main_time;
}

static uint32_t drive(Vplex_chrome_fabchrome_tb* t, uint32_t din) {
    t->din = din;
    t->de_in = 1;
    t->hs_in = 1;
    t->vs_in = 1;
    tick(t);
    return static_cast<uint32_t>(t->dout);
}

static void hblank(Vplex_chrome_fabchrome_tb* t) {
    t->de_in = 0;
    tick(t);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const bool red = std::getenv("FAULT_NO_FAB_CHROME") != nullptr;

    auto* t = new Vplex_chrome_fabchrome_tb;
    const int W = 1280;
    const int H = 720;
    t->reset = 1;
    t->clk = 0;
    t->HDMI_WIDTH = W;
    t->HDMI_HEIGHT = H;
    t->din = 0;
    t->hs_in = 0;
    t->vs_in = 0;
    t->de_in = 0;
    t->chrome_sig_en = red ? 0 : 1;
    t->chrome_demo_en = red ? 0 : 1;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);

    // 1-cycle delay: prime
    (void)drive(t, 0x001100);
    hblank(t);

    const uint32_t kVideo = 0x001100; // dark green underlay
    const uint32_t kMag = 0xFF2D95;
    const uint32_t kWhite = 0xFFFFFF;
    const uint32_t kAmber = 0xFFB220;
    const uint32_t kPanel = 0x141428;

    int mag = 0, white = 0, amber = 0, panel = 0, video = 0, other = 0;
    // Subsample every 4th pixel for speed; cover full frame.
    for (int y = 0; y < H; y += 2) {
        for (int x = 0; x < W; x += 2) {
            // Align pipeline: drive W pixels per line with blanks
        }
    }
    // Full-line drive for accurate coords (hx advances per DE beat)
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            uint32_t px = drive(t, kVideo);
            // dout is delayed 1 cycle — first pixel of frame is junk; skip x==0&&y==0 after prime
            if (y == 0 && x == 0)
                continue;
            // Sample every 4th
            if ((x & 3) || (y & 3))
                continue;
            if (px == kMag)
                ++mag;
            else if (px == kWhite)
                ++white;
            else if (px == kAmber)
                ++amber;
            else if (px == kPanel)
                ++panel;
            else if (px == kVideo)
                ++video;
            else
                ++other;
        }
        hblank(t);
    }

    // Corner probes (pipeline-aligned: after full scan we can't easily re-seek;
    // use subsample counts instead)
    std::fprintf(stderr, "fabchrome subsample mag=%d white=%d amber=%d panel=%d video=%d other=%d red=%d\n",
                 mag, white, amber, panel, video, other, red ? 1 : 0);

    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    if (red) {
        // Must look like pure video — no fabric chrome
        if (mag != 0)
            fail("red-magenta-present");
        if (white != 0)
            fail("red-white-present");
        if (amber != 0)
            fail("red-amber-present");
        if (panel != 0)
            fail("red-panel-present");
        if (video < 10000)
            fail("red-video-missing");
        else
            std::fprintf(stderr, "PASS fabchrome-red-no-paint\n");
    } else {
        if (mag < 50)
            fail("green-magenta-low");
        else
            std::fprintf(stderr, "PASS fabchrome-magenta\n");
        if (white < 20)
            fail("green-stopped-glyphs-low");
        else
            std::fprintf(stderr, "PASS fabchrome-stopped-glyphs\n");
        if (amber < 10)
            fail("green-amber-bar-low");
        else
            std::fprintf(stderr, "PASS fabchrome-amber-bar\n");
        if (panel < 100)
            fail("green-panel-low");
        else
            std::fprintf(stderr, "PASS fabchrome-panel\n");
        if (video < 1000)
            fail("green-video-underlay-lost");
        else
            std::fprintf(stderr, "PASS fabchrome-video-underlay\n");
    }

    if (fails) {
        std::fprintf(stderr, "plex_chrome_fabchrome_tb: %d FAIL(s)\n", fails);
        delete t;
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_fabchrome_tb: PASS\n");
    delete t;
    return 0;
}
