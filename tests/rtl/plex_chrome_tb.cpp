// Verilator TB for plex_chrome — passthrough, glyph hit, idle fabric.
// Red-before-green: disabled overlay must not alter video; idle must paint.

#include "Vplex_chrome_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_chrome_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static uint64_t packGlyph(uint16_t x, uint16_t y, char c) {
    uint64_t w = 2ull;
    w |= static_cast<uint64_t>(x) << 8;
    w |= static_cast<uint64_t>(y) << 24;
    w |= static_cast<uint64_t>(static_cast<uint8_t>(c)) << 40;
    return w;
}

static uint64_t packPlxc(bool en, unsigned count, uint16_t seq) {
    uint64_t w = 0x504C5843ull;
    if (en)
        w |= 1ull << 32;
    w |= (static_cast<uint64_t>(count) & 0x3FFFull) << 34;
    w |= static_cast<uint64_t>(seq) << 48;
    return w;
}

static void hostWrite(Vplex_chrome_tb* t, uint8_t addr, uint64_t data) {
    t->host_we = 1;
    t->host_addr = addr;
    t->host_wdata = data;
    tick(t);
    t->host_we = 0;
    tick(t);
}

// Drive one DE pixel and return dout after pipeline (1 cycle delay in chrome)
static uint32_t drivePixel(Vplex_chrome_tb* t, uint32_t din, int& hx, int hy, int width) {
    t->din = din;
    t->de_in = 1;
    t->hs_in = 1;
    t->vs_in = 1;
    tick(t);
    hx++;
    if (hx >= width) {
        // end of line pulse
        t->de_in = 0;
        tick(t);
        hx = 0;
    }
    return static_cast<uint32_t>(t->dout);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* which = std::getenv("CHROME_CASE");
    std::string cse = which ? which : "all";

    auto* t = new Vplex_chrome_tb;
    t->reset = 1;
    t->clk = 0;
    t->HDMI_WIDTH = 64;
    t->HDMI_HEIGHT = 48; // body_scale = 2 (48/240 → clamp 2)
    t->din = 0;
    t->hs_in = 0;
    t->vs_in = 0;
    t->de_in = 0;
    t->host_we = 0;
    t->host_addr = 0;
    t->host_wdata = 0;
    t->has_frame = 1;
    t->osd_idle_mode = 0;
    t->idle_phase_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);

    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    // ---- CASE passthrough: overlay off → dout == din (after 1 cycle) ----
    if (cse == "all" || cse == "passthrough") {
        std::fprintf(stderr, "=== passthrough (overlay off) ===\n");
        // ensure disable
        hostWrite(t, 0xFF, packPlxc(false, 0, 99));
        // vs rising to latch
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        tick(t);
        tick(t);

        const uint32_t colors[] = {0x112233, 0xAABBCC, 0x000000, 0xFFFFFF};
        // Design delays video by 1 cycle: dout[n] == din[n-1] while DE is high.
        t->de_in = 1;
        t->din = colors[0];
        tick(t); // prime din_d
        for (size_t i = 1; i < sizeof(colors) / sizeof(colors[0]); ++i) {
            t->din = colors[i];
            t->de_in = 1;
            tick(t);
            if (static_cast<uint32_t>(t->dout) != colors[i - 1]) {
                std::fprintf(stderr, "passthrough mismatch dout=%06x want=%06x\n",
                             static_cast<unsigned>(t->dout), colors[i - 1]);
                fail("passthrough");
            }
        }
        // Drain last color
        t->din = 0x555555;
        tick(t);
        if (static_cast<uint32_t>(t->dout) != colors[3]) {
            std::fprintf(stderr, "passthrough drain mismatch dout=%06x want=%06x\n",
                         static_cast<unsigned>(t->dout), colors[3]);
            fail("passthrough");
        }
        t->de_in = 0;
        if (fails == 0)
            std::fprintf(stderr, "PASS passthrough\n");
    }

    // ---- CASE glyph: solid # at (8,8) scale2 → white ink ----
    if (cse == "all" || cse == "glyph") {
        std::fprintf(stderr, "=== glyph hit ===\n");
        hostWrite(t, 0, packGlyph(8, 8, '#'));
        hostWrite(t, 0xFF, packPlxc(true, 1, 1));
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        for (int i = 0; i < 3; ++i)
            tick(t);

        // Scan a small window; count white pixels near glyph.
        // Sample dout only when de_out is high (1-cycle pipeline).
        int white = 0;
        int total = 0;
        for (int y = 0; y < 40; ++y) {
            t->de_in = 0;
            tick(t);
            t->de_in = 1;
            for (int x = 0; x < 64; ++x) {
                t->din = 0x102030;
                tick(t);
                if (t->de_out) {
                    ++total;
                    if (static_cast<uint32_t>(t->dout) == 0xFFFFFFu)
                        ++white;
                }
            }
            t->de_in = 0;
            tick(t); // drain last DE pixel onto de_out
            if (t->de_out) {
                ++total;
                if (static_cast<uint32_t>(t->dout) == 0xFFFFFFu)
                    ++white;
            }
        }
        std::fprintf(stderr, "glyph white=%d total=%d scale_mon=%u\n", white, total,
                     static_cast<unsigned>(t->mon_body_scale));
        // 8x8 font * scale2 = 16x16 = 256 max; solid # is full ink
        if (white < 100)
            fail("glyph white too low");
        if (t->mon_body_scale != 2)
            fail("body_scale expected 2");
        if (fails == 0)
            std::fprintf(stderr, "PASS glyph\n");
    }

    // ---- CASE idle: has_frame=0, mode logo → amber/bg, not video ----
    if (cse == "all" || cse == "idle") {
        std::fprintf(stderr, "=== fabric idle ===\n");
        // disable list
        hostWrite(t, 0xFF, packPlxc(false, 0, 2));
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        tick(t);
        t->has_frame = 0;
        t->osd_idle_mode = 0; // logo
        for (int i = 0; i < 4; ++i)
            tick(t);
        if (!t->idle_en_mon)
            fail("idle_en not asserted");

        int amber = 0, bg = 0, video = 0;
        auto score = [&](uint32_t d) {
            if (d == 0x00FF00)
                ++video;
            else if ((d >> 16) == 0xE5)
                ++amber;
            else if ((d >> 16) == 0x1F)
                ++bg;
        };
        for (int y = 0; y < 48; ++y) {
            t->de_in = 0;
            tick(t);
            t->de_in = 1;
            for (int x = 0; x < 64; ++x) {
                t->din = 0x00FF00; // green video must be replaced
                tick(t);
                if (t->de_out)
                    score(static_cast<uint32_t>(t->dout));
            }
            t->de_in = 0;
            tick(t); // drain
            if (t->de_out)
                score(static_cast<uint32_t>(t->dout));
        }
        std::fprintf(stderr, "idle amber=%d bg=%d video_leaked=%d\n", amber, bg, video);
        if (video > 10)
            fail("idle leaked video");
        if (amber < 5)
            fail("idle no chevron");
        if (bg < 100)
            fail("idle no background");
        if (fails == 0)
            std::fprintf(stderr, "PASS idle\n");
    }

    // chrome_hw sticky
    if (!t->chrome_hw)
        fail("chrome_hw not 1");

    delete t;
    if (fails) {
        std::fprintf(stderr, "plex_chrome_tb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_tb: PASS\n");
    return 0;
}
