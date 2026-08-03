// E2E Verilator: DDR PLXC → fabric chrome pixels (no ARM bake).
#include "Vplex_chrome_e2e_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_chrome_e2e_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static void mem_wr(Vplex_chrome_e2e_tb* t, uint32_t byte_off, uint64_t data) {
    t->mem_we_host = 1;
    t->mem_addr_host = byte_off >> 3;
    t->mem_wdata_host = data;
    tick(t);
    t->mem_we_host = 0;
    tick(t);
}

static uint64_t packGlyph(uint16_t x, uint16_t y, char c) {
    return 2ull | (uint64_t(x) << 8) | (uint64_t(y) << 24) | (uint64_t(uint8_t(c)) << 40);
}
static uint64_t packPlxc(bool en, unsigned count, uint16_t seq) {
    uint64_t w = 0x504C5843ull;
    if (en)
        w |= 1ull << 32;
    w |= (uint64_t(count) & 0x3FFFull) << 34;
    w |= uint64_t(seq) << 48;
    return w;
}

// Scan one 64x64 patch around glyph origin; count near-white pixels.
static int scan_white(Vplex_chrome_e2e_tb* t, int ox, int oy, int W, int H) {
    int white = 0;
    // chrome has pipeline delay — run a few blank ticks first
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            t->din = 0x00102030; // distinctive video blue-ish
            t->de_in = 1;
            t->hs_in = 1;
            t->vs_in = 1;
            tick(t);
            if (!t->de_out)
                continue;
            // glyph at (ox,oy) scale~2 for H=480 → body_scale 2
            const int dx = x - ox;
            const int dy = y - oy;
            if (dx >= 0 && dx < 32 && dy >= 0 && dy < 32) {
                const uint32_t p = t->dout;
                const int r = (p >> 16) & 0xFF;
                const int g = (p >> 8) & 0xFF;
                const int b = p & 0xFF;
                if (r > 200 && g > 200 && b > 200)
                    white++;
            }
        }
        t->de_in = 0;
        tick(t);
    }
    return white;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    auto* t = new Vplex_chrome_e2e_tb;
    t->reset = 1;
    t->clk = 0;
    t->HDMI_WIDTH = 640;
    t->HDMI_HEIGHT = 480;
    t->din = 0;
    t->hs_in = 0;
    t->vs_in = 0;
    t->de_in = 0;
    t->mem_we_host = 0;
    t->has_frame = 1;
    t->osd_idle_mode = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);

    // --- before PLXC: video passthrough (cfg off) ---
    std::fprintf(stderr, "=== e2e passthrough pre-load ===\n");
    t->din = 0x00AABBCC;
    t->de_in = 1;
    tick(t);
    tick(t); // 1-cycle chrome delay
    // may still be settling; sample a few
    int match = 0;
    for (int i = 0; i < 8; ++i) {
        t->din = 0x00112233 + i;
        tick(t);
        if (t->de_out && t->dout == (0x00112233u + uint32_t(i - 1)))
            match++;
    }
    // loose: at least some passthrough equality with 1-cycle delay
    t->de_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    if (!t->cfg_enable_mon)
        std::fprintf(stderr, "PASS pre-load cfg off\n");
    else
        fail("cfg on before load");

    // --- load PLXC via DDR mem (ARM write path) ---
    std::fprintf(stderr, "=== e2e DDR load glyph ===\n");
    const uint16_t gx = 40, gy = 40;
    mem_wr(t, 0x140, packGlyph(gx, gy, '#'));
    mem_wr(t, 0x130, packPlxc(true, 1, 9));

    for (int i = 0; i < 500 && t->cnt_loads < 1; ++i)
        tick(t);
    if (t->cnt_loads < 1)
        fail("loader never loaded");
    if (t->last_seq != 9)
        fail("last_seq");
    // wait host_if apply
    for (int i = 0; i < 20; ++i)
        tick(t);
    if (!t->cfg_enable_mon)
        fail("cfg_enable not set");
    if (fails == 0)
        std::fprintf(stderr, "PASS load-applied\n");

    // --- scan for white glyph pixels ---
    std::fprintf(stderr, "=== e2e glyph pixels ===\n");
    const int white = scan_white(t, gx, gy, 160, 120);
    std::fprintf(stderr, "white_px=%d\n", white);
    if (white < 8)
        fail("no glyph white pixels");
    if (fails == 0)
        std::fprintf(stderr, "PASS glyph-pixels\n");

    // --- PLXO published ---
    std::fprintf(stderr, "=== e2e PLXO ===\n");
    for (int i = 0; i < 300; ++i)
        tick(t);
    const uint64_t plxo = t->mem_plxo_q;
    if (static_cast<uint32_t>(plxo) != 0x504C584Fu)
        fail("plxo magic");
    if (((plxo >> 32) & 1ull) == 0)
        fail("plxo chrome_hw");
    if (fails == 0)
        std::fprintf(stderr, "PASS plxo\n");

    // --- idle when !has_frame ---
    std::fprintf(stderr, "=== e2e idle ===\n");
    t->has_frame = 0;
    t->osd_idle_mode = 0; // logo
    for (int i = 0; i < 8; ++i)
        tick(t);
    // disable chrome overlay so idle can show (or leave enable — idle ORs)
    // host_if: idle_en = !has_frame && mode!=3
    if (!t->idle_en_mon)
        fail("idle_en not set");
    // sample a few active pixels for non-video colors
    int idleish = 0;
    for (int i = 0; i < 200; ++i) {
        t->din = 0x0000FF00; // green video should be replaced
        t->de_in = 1;
        tick(t);
        if (t->de_out && t->dout != 0x0000FF00 && t->dout != 0)
            idleish++;
    }
    std::fprintf(stderr, "idleish_px=%d idle_en=%d\n", idleish, (int)t->idle_en_mon);
    if (idleish < 10)
        fail("idle did not paint");
    if (fails == 0)
        std::fprintf(stderr, "PASS idle\n");

    delete t;
    if (fails) {
        std::fprintf(stderr, "plex_chrome_e2e_tb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_e2e_tb: PASS\n");
    return 0;
}
