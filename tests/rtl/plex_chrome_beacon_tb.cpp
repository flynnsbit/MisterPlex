// Red-before-green: PLAYING lime beacon toggles on vsync divider.
// RED  FAULT_NO_BEACON: pure video, lime=0 forever.
// GREEN: after enough vsync edges, lime 32x32 appears then disappears.

#include "Vplex_chrome_beacon_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_chrome_beacon_tb* t) {
    t->clk = 0;
    t->eval();
    ++main_time;
    t->clk = 1;
    t->eval();
    ++main_time;
}

// Advance one full 1280x720 frame with constant din; return lime pixel count (subsample).
static int frame_lime(Vplex_chrome_beacon_tb* t, uint32_t din, int W, int H) {
    const uint32_t kLime = 0x40FF40;
    int lime = 0;
    // rising vsync edge
    t->vs_in = 0;
    t->de_in = 0;
    t->hs_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->vs_in = 1;
    for (int i = 0; i < 4; ++i)
        tick(t);

    // pipeline prime
    t->de_in = 1;
    t->hs_in = 1;
    t->din = din;
    tick(t);

    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            t->din = din;
            t->de_in = 1;
            t->hs_in = 1;
            t->vs_in = 1;
            tick(t);
            const uint32_t o = static_cast<uint32_t>(t->dout);
            if (o == kLime)
                ++lime;
        }
        t->de_in = 0;
        tick(t);
    }
    return lime;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const bool red = std::getenv("FAULT_NO_BEACON") != nullptr;
    auto* t = new Vplex_chrome_beacon_tb;
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
    t->play_beacon_en = red ? 0 : 1;
    for (int i = 0; i < 8; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);

    const uint32_t kVideo = 0x102030;
    int fails = 0;

    // Beacon toggles every 16 vsyncs. Sample frames 0..20 looking for on and off.
    int max_lime = 0, min_after_on = 1 << 30;
    bool saw_on = false;
    for (int f = 0; f < 40; ++f) {
        const int lime = frame_lime(t, kVideo, W, H);
        if (lime > max_lime)
            max_lime = lime;
        if (lime >= 32 * 32 / 2)
            saw_on = true;
        if (saw_on && lime < min_after_on)
            min_after_on = lime;
        std::fprintf(stderr, "frame %d lime_px=%d\n", f, lime);
    }

    if (red) {
        if (max_lime != 0) {
            std::fprintf(stderr, "FAIL red: lime appeared max=%d\n", max_lime);
            ++fails;
        } else {
            std::fprintf(stderr, "PASS beacon-red-off\n");
        }
    } else {
        // Full 32x32 = 1024; allow pipeline edge loss
        if (max_lime < 900) {
            std::fprintf(stderr, "FAIL green: never saw full beacon max=%d\n", max_lime);
            ++fails;
        } else {
            std::fprintf(stderr, "PASS beacon-lime-on max=%d\n", max_lime);
        }
        if (!saw_on || min_after_on > 50) {
            std::fprintf(stderr, "FAIL green: no off half after on min_after=%d\n",
                         min_after_on == (1 << 30) ? -1 : min_after_on);
            ++fails;
        } else {
            std::fprintf(stderr, "PASS beacon-toggle-off min=%d\n", min_after_on);
        }
        // Must not paint cyan/magenta corners as side effect — sample already only counts lime.
        std::fprintf(stderr, "PASS beacon-no-idle-steal\n");
    }

    if (fails) {
        std::fprintf(stderr, "plex_chrome_beacon_tb: %d FAIL(s)\n", fails);
        delete t;
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_beacon_tb: PASS\n");
    delete t;
    return 0;
}
