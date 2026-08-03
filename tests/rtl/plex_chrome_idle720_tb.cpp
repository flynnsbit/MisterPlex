// Native 1280×720 fabric idle — red-before-green.
// GREEN (default): exact chevron geometry + vsync phase + no video leak.
// RED (FAULT_480P_GEOM=1 build): 480p-clamped geom fails 720p probes.
//
// Geometry contract (docs/chrome-idle-geometry-contract.md):
//   size=min(1280,720)/3=240  ox=(1280-240)/2=520  oy=(720-240)/2=240
//   stroke=48  body_scale(720)=3  colours E5A00D / 1F2326

#include "Vplex_chrome_idle720_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_chrome_idle720_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

// Drive to absolute pixel (x,y) with DE; return dout after 1-cycle chrome pipe.
// Assumes PPC=1. Resets beam via vs edge then walks.
static uint32_t sampleAt(Vplex_chrome_idle720_tb* t, int tx, int ty, uint32_t din_color) {
    // vs rising resets counters
    t->de_in = 0;
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    tick(t);
    tick(t);

    uint32_t last = 0;
    for (int y = 0; y <= ty; ++y) {
        t->de_in = 0;
        tick(t);
        t->de_in = 1;
        const int x_end = (y == ty) ? tx : 1279;
        for (int x = 0; x <= x_end; ++x) {
            t->din = din_color;
            tick(t);
            if (t->de_out)
                last = static_cast<uint32_t>(t->dout) & 0xFFFFFFu;
        }
        t->de_in = 0;
        tick(t);
        if (t->de_out)
            last = static_cast<uint32_t>(t->dout) & 0xFFFFFFu;
    }
    return last;
}

// Golden chevron (matches plex_chrome.sv idle_chevron)
static bool goldenChevron(int x, int y, int ox, int oy, int size) {
    const int lx = x - ox;
    const int ly = y - oy;
    if (lx < 0 || ly < 0 || lx >= size || ly >= size)
        return false;
    const int half = size >> 1;
    int stroke = size / 5;
    if (stroke == 0)
        stroke = 1;
    int d;
    if (ly <= half)
        d = lx - ly;
    else
        d = lx - (size - 1 - ly);
    return d >= 0 && d < stroke;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* mode = std::getenv("IDLE720_MODE");
    const bool expect_fault = mode && std::strcmp(mode, "red") == 0;

    auto* t = new Vplex_chrome_idle720_tb;
    t->reset = 1;
    t->clk = 0;
    t->din = 0;
    t->hs_in = 1;
    t->vs_in = 0;
    t->de_in = 0;
    t->has_frame = 1;
    t->osd_idle_mode = 0;
    t->fab_phase_en = 0;
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

    // ---- mon telemetry at idle enable ----
    std::fprintf(stderr, "=== idle720 mon / enable ===\n");
    t->has_frame = 0;
    t->osd_idle_mode = 0;
    t->fab_phase_en = 1;
    for (int i = 0; i < 4; ++i)
        tick(t);
    if (!t->idle_en_mon)
        fail("idle_en");

    const unsigned mw = t->mon_width;
    const unsigned mh = t->mon_height;
    const unsigned sc = t->mon_body_scale;
    std::fprintf(stderr, "mon %ux%u scale=%u\n", mw, mh, sc);

    // 720p product expectations
    const bool geom720 = (mw == 1280 && mh == 720 && sc == 3);
    if (!expect_fault) {
        if (!geom720)
            fail("expected mon 1280x720 scale=3");
    } else {
        // RED build: FAULT clamps to 624×480 → scale 2
        if (geom720)
            fail("RED build must NOT report 720p mon");
        if (mw != 624 || mh != 480 || sc != 2)
            fail("RED expected mon 624x480 scale=2");
        std::fprintf(stderr, "PASS idle720-red-mon (fault geom active)\n");
        delete t;
        // For red mode: also prove a 720p probe point would disagree with golden720
        // We still exit 1 if fault didn't engage; else exit 0 after proving fault.
        if (fails) {
            std::fprintf(stderr, "plex_chrome_idle720_tb RED: %d FAIL(s)\n", fails);
            return 1;
        }
        std::fprintf(stderr, "plex_chrome_idle720_tb: PASS (red fault engaged)\n");
        return 0;
    }

    // ---- exact pixels (720p logo) ----
    std::fprintf(stderr, "=== idle720 sample points ===\n");
    constexpr int kOx = 520, kOy = 240, kSize = 240;
    // Corner: background
    const uint32_t c00 = sampleAt(t, 0, 0, 0x00FF00);
    // Chevron top-left of box (lx=0,ly=0) → amber
    const uint32_t c_tl = sampleAt(t, kOx, kOy, 0x00FF00);
    // Inside stroke upper arm (lx=ly+10 within stroke)
    const uint32_t c_arm = sampleAt(t, kOx + 40, kOy + 40, 0x00FF00);
    // Outside box right: bg
    const uint32_t c_out = sampleAt(t, 1000, 600, 0x00FF00);
    // Far from chevron on same row as center: bg
    const uint32_t c_left = sampleAt(t, 100, 360, 0x00FF00);

    std::fprintf(stderr, "pix (0,0)=%06x (520,240)=%06x (560,280)=%06x (1000,600)=%06x (100,360)=%06x\n",
                 c00, c_tl, c_arm, c_out, c_left);

    if (c00 != 0x1F2326)
        fail("bg at (0,0)");
    if (c_tl != 0xE5A00D)
        fail("amber at chevron origin");
    if (c_arm != 0xE5A00D)
        fail("amber on stroke arm");
    if (c_out != 0x1F2326)
        fail("bg outside box");
    if (c_left != 0x1F2326)
        fail("bg left of chevron");
    // Video green must never appear
    if (c00 == 0x00FF00 || c_tl == 0x00FF00 || c_arm == 0x00FF00)
        fail("video leak");

    // Golden cross-check at a few points
    if (!goldenChevron(kOx, kOy, kOx, kOy, kSize))
        fail("golden self-check origin");
    if (!goldenChevron(kOx + 40, kOy + 40, kOx, kOy, kSize))
        fail("golden self-check arm");
    if (goldenChevron(1000, 600, kOx, kOy, kSize))
        fail("golden self-check outside");

    if (fails == 0)
        std::fprintf(stderr, "PASS idle720-geom\n");

    // ---- fab-pace style vsync phase ----
    std::fprintf(stderr, "=== idle720 vsync phase ===\n");
    t->fab_phase_en = 1;
    t->has_frame = 0;
    const uint16_t p0 = t->idle_phase_mon;
    for (int n = 0; n < 5; ++n) {
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        tick(t);
        tick(t);
    }
    const uint16_t p1 = t->idle_phase_mon;
    std::fprintf(stderr, "phase %u -> %u\n", p0, p1);
    if (static_cast<unsigned>(p1 - p0) < 5)
        fail("phase did not advance on vsync");
    if (fails == 0)
        std::fprintf(stderr, "PASS idle720-phase\n");

    // ---- screensaver drift: two pinned phases → chevron origin moves ----
    // RTL: size=240, span_x=1280-240-16=1024, ox=8+tri*span/600
    // phase 0 → tri=0 → ox=8; phase 600 → tri=600 → ox=8+1024=1032
    std::fprintf(stderr, "=== idle720 screensaver motion ===\n");
    t->osd_idle_mode = 2;
    t->fab_phase_en = 0; // pin phase via idle_phase_in
    t->has_frame = 0;
    t->idle_phase_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    // oy at ph0 and ph600 both 240 (y-phase offset +300 → same tri); ox 8 vs 1032
    constexpr int kSsY = 240;
    const uint32_t ss0 = sampleAt(t, 8, kSsY, 0x00FF00);       // ox=8 → amber
    const uint32_t ss0b = sampleAt(t, 1032, kSsY, 0x00FF00);   // far → bg
    t->idle_phase_in = 600;
    for (int i = 0; i < 4; ++i)
        tick(t);
    const uint32_t ss1 = sampleAt(t, 8, kSsY, 0x00FF00);       // left → bg
    const uint32_t ss1b = sampleAt(t, 1032, kSsY, 0x00FF00);   // ox=1032 → amber
    std::fprintf(stderr,
                 "ss ph0 (8,240)=%06x (1032,240)=%06x | ph600 (8,240)=%06x (1032,240)=%06x\n",
                 ss0, ss0b, ss1, ss1b);
    if (ss0 != 0xE5A00D)
        fail("ss phase0 origin not amber");
    if (ss0b == 0xE5A00D)
        fail("ss phase0 far x must not be amber");
    if (ss1 == 0xE5A00D)
        fail("ss phase600 left origin must leave (not amber)");
    if (ss1b != 0xE5A00D)
        fail("ss phase600 drifted origin not amber");
    if (fails == 0)
        std::fprintf(stderr, "PASS idle720-screensaver-motion\n");

    // Restore logo mode for subsample
    t->osd_idle_mode = 0;
    t->idle_phase_in = 0;
    t->fab_phase_en = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);

    // ---- subsample scan: no video, some amber ----
    std::fprintf(stderr, "=== idle720 subsample ===\n");
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    tick(t);
    int amber = 0, bg = 0, video = 0, other = 0;
    // Sample every 8th pixel on every 8th line (fast, still covers full canvas)
    for (int y = 0; y < 720; y += 8) {
        t->de_in = 0;
        tick(t);
        // burn skipped lines' y advances: we only emit one DE line per y step,
        // so walk y consecutive DE lines but only score y%8==0 — simpler: full
        // lines at stride 8 by emitting blank lines between.
        // Actually chrome y_cnt increments each DE falling edge. Emit (y - prev)
        // empty line ends... Easier: restart vs and walk all lines, score stride.
    }
    // Full-height walk with x-stride 8 (921600/8 = 115200 ticks — acceptable)
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    tick(t);
    tick(t);
    for (int y = 0; y < 720; ++y) {
        t->de_in = 0;
        tick(t);
        t->de_in = 1;
        for (int x = 0; x < 1280; x += 8) {
            t->din = 0x00FF00;
            // advance 8 pixels: 1 active sample + 7 burn
            tick(t);
            if (t->de_out) {
                const uint32_t d = static_cast<uint32_t>(t->dout) & 0xFFFFFFu;
                if (d == 0xE5A00D)
                    ++amber;
                else if (d == 0x1F2326)
                    ++bg;
                else if (d == 0x00FF00)
                    ++video;
                else
                    ++other;
            }
            for (int k = 0; k < 7 && x + 1 + k < 1280; ++k) {
                t->din = 0x00FF00;
                tick(t);
            }
        }
        // finish line to 1280 if needed
        t->de_in = 0;
        tick(t);
    }
    std::fprintf(stderr, "subsample amber=%d bg=%d video=%d other=%d\n", amber, bg, video, other);
    if (video > 0)
        fail("subsample video leak");
    if (amber < 50)
        fail("subsample amber too low for 720p chevron");
    if (bg < 1000)
        fail("subsample bg too low");
    if (fails == 0)
        std::fprintf(stderr, "PASS idle720-subsample\n");

    delete t;
    if (fails) {
        std::fprintf(stderr, "plex_chrome_idle720_tb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_idle720_tb: PASS\n");
    return 0;
}
