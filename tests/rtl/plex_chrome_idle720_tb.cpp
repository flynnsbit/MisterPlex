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
// Assumes PPC=1. Resets beam via vs edge then walks. Line width from mon_width.
static uint32_t sampleAt(Vplex_chrome_idle720_tb* t, int tx, int ty, uint32_t din_color) {
    const int line_w = static_cast<int>(t->mon_width) > 0 ? static_cast<int>(t->mon_width) - 1 : 1279;
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
        const int x_end = (y == ty) ? tx : line_w;
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
    // red: FAULT_480P_GEOM. legacy: 480p paint on 720p beam.
    // hdmi_on_de: HDMI 1280×720 paint math on CORE_DE 960×540 beam (pivot class).
    // corede: green pre-ascal insertion (beam+layout 960×540).
    const bool expect_fault = mode && std::strcmp(mode, "red") == 0;
    const bool expect_legacy = mode && std::strcmp(mode, "legacy") == 0;
    const bool expect_hdmi_on_de = mode && std::strcmp(mode, "hdmi_on_de") == 0;
    const bool expect_corede = mode && std::strcmp(mode, "corede") == 0;
    // 10-bit X counter wraps at 1024 — right-edge glass must not match product.
    const bool expect_narrow_x = mode && std::strcmp(mode, "narrow_x") == 0;

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
    t->idle_sig_en = 0;
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

    // Beam telemetry expectations (mon tracks paint beam, not fault layout)
    const bool geom720 = (mw == 1280 && mh == 720 && sc == 3);
    const bool geom540 = (mw == 960 && mh == 540 && sc == 2);
    if (expect_fault) {
        // RED build: FAULT clamps HDMI ports to 624×480 → scale 2
        if (geom720)
            fail("RED build must NOT report 720p mon");
        if (mw != 624 || mh != 480 || sc != 2)
            fail("RED expected mon 624x480 scale=2");
        std::fprintf(stderr, "PASS idle720-red-mon (fault geom active)\n");
        delete t;
        if (fails) {
            std::fprintf(stderr, "plex_chrome_idle720_tb RED: %d FAIL(s)\n", fails);
            return 1;
        }
        std::fprintf(stderr, "plex_chrome_idle720_tb: PASS (red fault engaged)\n");
        return 0;
    }

    if (expect_hdmi_on_de) {
        // Beam is CORE_DE 960×540; layout fault forces 1280×720 paint math.
        // Correct DE chevron: size=180 ox=390 oy=180. HDMI math: size=240 ox=520 oy=240.
        std::fprintf(stderr, "=== idle720 hdmi-layout-on-core-DE red-twin ===\n");
        if (!geom540)
            fail("hdmi_on_de expected mon 960x540 scale=2");
        t->idle_sig_en = 0;
        for (int i = 0; i < 2; ++i)
            tick(t);
        constexpr int kOxDe = 390, kOyDe = 180;
        constexpr int kOxHdmi = 520, kOyHdmi = 240;
        const uint32_t at_de = sampleAt(t, kOxDe, kOyDe, 0x00FF00);
        const uint32_t at_hdmi = sampleAt(t, kOxHdmi, kOyHdmi, 0x00FF00);
        std::fprintf(stderr, "hdmi_on_de pix (390,180)=%06x (520,240)=%06x\n", at_de, at_hdmi);
        if (at_de == 0xE5A00D)
            fail("hdmi_on_de still paints amber at CORE_DE chevron origin");
        if (at_hdmi != 0xE5A00D)
            fail("hdmi_on_de must paint amber at HDMI-derived origin on 540 beam");
        if (fails == 0)
            std::fprintf(stderr, "PASS idle720-hdmi-layout-on-core-de\n");
        delete t;
        if (fails) {
            std::fprintf(stderr, "plex_chrome_idle720_tb HDMI_ON_DE: %d FAIL(s)\n", fails);
            return 1;
        }
        std::fprintf(stderr, "plex_chrome_idle720_tb: PASS (hdmi layout on core DE fault engaged)\n");
        return 0;
    }

    if (expect_corede) {
        // Green pre-ascal insertion: beam+layout 960×540.
        std::fprintf(stderr, "=== idle720 CORE_DE green (pre-ascal insertion) ===\n");
        if (!geom540)
            fail("corede expected mon 960x540 scale=2");
        t->idle_sig_en = 0;
        for (int i = 0; i < 2; ++i)
            tick(t);
        constexpr int kOx = 390, kOy = 180;
        const uint32_t at = sampleAt(t, kOx, kOy, 0x00FF00);
        std::fprintf(stderr, "corede pix (390,180)=%06x\n", at);
        if (at != 0xE5A00D)
            fail("corede chevron missing at 960x540 origin");
        // HDMI origin must not be the chevron centre on this beam
        const uint32_t at_hdmi = sampleAt(t, 520, 240, 0x00FF00);
        if (at_hdmi == 0xE5A00D)
            fail("corede must not use HDMI 720p chevron origin");
        if (fails == 0)
            std::fprintf(stderr, "PASS idle720-corede-geom\n");
        delete t;
        if (fails) {
            std::fprintf(stderr, "plex_chrome_idle720_tb COREDE: %d FAIL(s)\n", fails);
            return 1;
        }
        std::fprintf(stderr, "plex_chrome_idle720_tb: PASS (core DE green)\n");
        return 0;
    }

    if (!geom720)
        fail("expected mon 1280x720 scale=3");

    if (expect_narrow_x) {
        // Beam still 1280×720 mon; X counter is 10-bit → wraps every 1024 px.
        // Product BR cyan is at (1279,719). Narrow X maps 1279 → 1279-1024=255.
        // So (1279,719) must NOT be cyan; a wrapped-equivalent left coord may be.
        std::fprintf(stderr, "=== idle720 narrow-X (10b) red-twin ===\n");
        t->idle_sig_en = 1;
        for (int i = 0; i < 2; ++i)
            tick(t);
        const uint32_t br = sampleAt(t, 1279, 719, 0x00FF00);
        const uint32_t tl = sampleAt(t, 0, 0, 0x00FF00);
        std::fprintf(stderr, "narrow_x pix (0,0)=%06x (1279,719)=%06x\n", tl, br);
        if (tl != 0x00C8FF)
            fail("narrow_x TL cyan still required (x=0 in 10b range)");
        if (br == 0x00C8FF)
            fail("narrow_x must NOT paint BR cyan at true x=1279 (counter wraps)");
        // Product green must keep BR cyan — this red twin is the negative control.
        if (fails == 0)
            std::fprintf(stderr, "PASS idle720-narrow-x-wrap\n");
        delete t;
        if (fails) {
            std::fprintf(stderr, "plex_chrome_idle720_tb NARROW_X: %d FAIL(s)\n", fails);
            return 1;
        }
        std::fprintf(stderr, "plex_chrome_idle720_tb: PASS (narrow 10b X fault engaged)\n");
        return 0;
    }

    if (expect_legacy) {
        // Stronger red-twin: mon is honest 720p, but paint uses 480p layout.
        // Golden 720p chevron origin (520,240) must NOT be amber.
        // Legacy 480p origin: size=160 ox=232 oy=160 → that pixel IS amber.
        std::fprintf(stderr, "=== idle720 legacy-480p-layout red-twin ===\n");
        t->idle_sig_en = 0;
        for (int i = 0; i < 2; ++i)
            tick(t);
        constexpr int kOx720 = 520, kOy720 = 240;
        constexpr int kOx480 = 232, kOy480 = 160;
        const uint32_t at720 = sampleAt(t, kOx720, kOy720, 0x00FF00);
        const uint32_t at480 = sampleAt(t, kOx480, kOy480, 0x00FF00);
        std::fprintf(stderr, "legacy pix (520,240)=%06x (232,160)=%06x\n", at720, at480);
        if (at720 == 0xE5A00D)
            fail("legacy fault still paints amber at 720p chevron origin");
        if (at480 != 0xE5A00D)
            fail("legacy fault must paint amber at 480p-derived origin");
        if (fails == 0)
            std::fprintf(stderr, "PASS idle720-legacy-layout-fault\n");
        delete t;
        if (fails) {
            std::fprintf(stderr, "plex_chrome_idle720_tb LEGACY: %d FAIL(s)\n", fails);
            return 1;
        }
        std::fprintf(stderr, "plex_chrome_idle720_tb: PASS (legacy 480p layout fault engaged)\n");
        return 0;
    }

    // ---- exact pixels (720p logo) + fabric cyan signature ----
    std::fprintf(stderr, "=== idle720 sample points ===\n");
    constexpr int kOx = 520, kOy = 240, kSize = 240;
    t->idle_sig_en = 1; // fabric-only cyan corners
    for (int i = 0; i < 2; ++i)
        tick(t);
    // TL signature cyan (ARM never paints 00C8FF)
    const uint32_t c00 = sampleAt(t, 0, 0, 0x00FF00);
    const uint32_t c_br = sampleAt(t, 1279, 719, 0x00FF00);
    // Chevron top-left of box (lx=0,ly=0) → amber
    const uint32_t c_tl = sampleAt(t, kOx, kOy, 0x00FF00);
    // Inside stroke upper arm
    const uint32_t c_arm = sampleAt(t, kOx + 40, kOy + 40, 0x00FF00);
    // Outside box right: bg (not cyan — away from corners)
    const uint32_t c_out = sampleAt(t, 1000, 600, 0x00FF00);
    // Far from chevron on same row as center: bg
    const uint32_t c_left = sampleAt(t, 100, 360, 0x00FF00);

    std::fprintf(stderr,
                 "pix (0,0)=%06x (1279,719)=%06x (520,240)=%06x (560,280)=%06x "
                 "(1000,600)=%06x (100,360)=%06x\n",
                 c00, c_br, c_tl, c_arm, c_out, c_left);

    if (c00 != 0x00C8FF)
        fail("fabric cyan signature at TL");
    if (c_br != 0x00C8FF)
        fail("fabric cyan signature at BR");
    if (c_tl != 0xE5A00D)
        fail("amber at chevron origin");
    if (c_arm != 0xE5A00D)
        fail("amber on stroke arm");
    if (c_out != 0x1F2326)
        fail("bg outside box");
    if (c_left != 0x1F2326)
        fail("bg left of chevron");
    if (c00 == 0x00FF00 || c_tl == 0x00FF00 || c_arm == 0x00FF00)
        fail("video leak");

    // RED-distinguish: with sig OFF, corner must NOT be cyan (ARM-lookalike path)
    t->idle_sig_en = 0;
    for (int i = 0; i < 2; ++i)
        tick(t);
    const uint32_t nosig = sampleAt(t, 0, 0, 0x00FF00);
    if (nosig == 0x00C8FF)
        fail("sig off must not paint cyan");
    if (nosig != 0x1F2326)
        fail("sig off corner should be ARM-matching bg");
    t->idle_sig_en = 1;
    for (int i = 0; i < 2; ++i)
        tick(t);

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
    int amber = 0, bg = 0, cyan = 0, video = 0, other = 0;
    t->idle_sig_en = 1;
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
            tick(t);
            if (t->de_out) {
                const uint32_t d = static_cast<uint32_t>(t->dout) & 0xFFFFFFu;
                if (d == 0xE5A00D)
                    ++amber;
                else if (d == 0x00C8FF)
                    ++cyan;
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
        t->de_in = 0;
        tick(t);
    }
    std::fprintf(stderr, "subsample amber=%d cyan=%d bg=%d video=%d other=%d\n", amber, cyan, bg,
                 video, other);
    if (video > 0)
        fail("subsample video leak");
    if (amber < 50)
        fail("subsample amber too low for 720p chevron");
    if (cyan < 20)
        fail("subsample cyan signature too low");
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
