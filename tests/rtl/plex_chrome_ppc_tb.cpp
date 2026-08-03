// PX_PER_CLK=2: both lanes composite; off = dual passthrough; rect covers one lane only.
#include "Vplex_chrome_ppc_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_chrome_ppc_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static void host_wr(Vplex_chrome_ppc_tb* t, uint8_t a, uint64_t d) {
    t->host_we = 1;
    t->host_addr = a;
    t->host_wdata = d;
    tick(t);
    t->host_we = 0;
    tick(t);
}

static uint64_t packRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h) {
    return 1ull | (uint64_t(x) << 8) | (uint64_t(y) << 24) | (uint64_t(w & 0xFFF) << 40) |
           (uint64_t(h & 0xFFF) << 52);
}
static uint64_t packPlxc(bool en, unsigned c, uint16_t seq) {
    uint64_t w = 0x504C5843ull;
    if (en)
        w |= 1ull << 32;
    w |= (uint64_t(c) & 0x3FFFull) << 34;
    w |= uint64_t(seq) << 48;
    return w;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    auto* t = new Vplex_chrome_ppc_tb;
    t->reset = 1;
    t->HDMI_WIDTH = 1280;
    t->HDMI_HEIGHT = 720;
    t->din = 0;
    t->hs_in = 1;
    t->vs_in = 0;
    t->de_in = 0;
    t->host_we = 0;
    t->has_frame = 1;
    t->osd_idle_mode = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    // vs pulse to allow latch later
    t->vs_in = 1;
    tick(t);
    t->vs_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);

    // --- dual passthrough when overlay off ---
    std::fprintf(stderr, "=== ppc2 passthrough ===\n");
    t->de_in = 1;
    t->din = (uint64_t(0x00AA5500) << 24) | 0x00112233; // lane1 | lane0
    tick(t);
    tick(t);
    const uint32_t o0 = t->dout & 0xFFFFFFu;
    const uint32_t o1 = (t->dout >> 24) & 0xFFFFFFu;
    // after 1-cycle delay, din from previous
    t->din = (uint64_t(0x00BB6600) << 24) | 0x00445566;
    tick(t);
    if ((t->dout & 0xFFFFFFu) != 0x00112233)
        fail("lane0 passthrough");
    if (((t->dout >> 24) & 0xFFFFFFu) != 0x00AA5500)
        fail("lane1 passthrough");
    if (fails == 0)
        std::fprintf(stderr, "PASS ppc2-passthrough\n");

    // --- rect at x=0 w=1 → only lane0 on first beat ---
    std::fprintf(stderr, "=== ppc2 single-lane rect ===\n");
    t->de_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    host_wr(t, 0, packRect(0, 0, 1, 8));
    host_wr(t, 0xFF, packPlxc(true, 1, 1));
    t->vs_in = 1;
    tick(t);
    t->vs_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);

    // first active beat: x0=0, x1=1 — only x0 in rect
    t->de_in = 1;
    t->din = (uint64_t(0x0000FF00) << 24) | 0x000000FF; // green | blue video
    tick(t);
    tick(t);
    const uint32_t r0 = t->dout & 0xFFFFFFu;
    const uint32_t r1 = (t->dout >> 24) & 0xFFFFFFu;
    std::fprintf(stderr, "rect beat0 lane0=%06x lane1=%06x\n", r0, r1);
    if (r0 != 0x141428)
        fail("lane0 should be rect fill");
    if (r1 == 0x141428)
        fail("lane1 must NOT be rect (x=1 outside w=1)");
    // lane1 should be video (green) from delayed din
    if (r1 != 0x0000FF00 && r1 != 0x000000FF)
        fail("lane1 video");
    if (fails == 0)
        std::fprintf(stderr, "PASS ppc2-lane-split\n");

    // second beat x0=2,x1=3 — neither in rect
    tick(t);
    const uint32_t s0 = t->dout & 0xFFFFFFu;
    const uint32_t s1 = (t->dout >> 24) & 0xFFFFFFu;
    if (s0 == 0x141428 || s1 == 0x141428)
        fail("beat1 should be outside rect");
    if (fails == 0)
        std::fprintf(stderr, "PASS ppc2-outside\n");

    delete t;
    if (fails) {
        std::fprintf(stderr, "plex_chrome_ppc_tb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_ppc_tb: PASS\n");
    return 0;
}
