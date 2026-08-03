// B8 product hierarchy: PRESENT_BEAM_960 → 960×540 content/geom at present_core.
// Red twin A (FAULT_B8_NO_BEAM): no beam force → content 320/640 with PLXG idle.
// Red twin B: 1280×720 inject still Option-C capacity (host oracle via strides).
// B9: asserts Plex.sv VIDEO_ARX/VIDEO_ARY model (Full Screen 0/0 under beam).
#include "Vplex_b8_hier_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_b8_hier_tb_top* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    auto* t = new Vplex_b8_hier_tb_top;
    t->reset = 1;
    t->content_res_640x480 = 0;
    t->inject_plxg_live = 0;
    t->inject_cw = 0;
    t->inject_ch = 0;
    t->inject_coded_w = 0;
    t->inject_coded_h = 0;
    t->inject_y_stride = 0;
    t->inject_c_stride = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 32; ++i)
        tick(t);

#if defined(FAULT_B8_NO_BEAM)
    std::fprintf(stderr, "=== FAULT_B8_NO_BEAM red twin (expect non-960) ===\n");
    std::fprintf(stderr,
                 "fault: win=%u geom=%u cw=%u ch=%u coded=%ux%u yst=%u\n",
                 t->obs_win_en, t->obs_geom_en, t->obs_content_w, t->obs_content_h,
                 t->obs_coded_w, t->obs_coded_h, t->obs_y_stride);
    // Product defect: PLXG idle + no beam force → O[4] 320×240, geom off.
    if (t->obs_content_w == 960 && t->obs_content_h == 540) {
        fail("fault twin unexpectedly got 960×540 (cannot see B8 defect)");
    } else {
        std::fprintf(stderr, "REPRO b8-plxg-tied-legacy cw=%u ch=%u\n",
                     t->obs_content_w, t->obs_content_h);
        std::fprintf(stderr, "PASS fault twin reproduces legacy content\n");
    }
    // Intentionally fail the suite when run as fault build so shell sees RED.
    if (fails == 0) {
        std::fprintf(stderr, "FAULT_B8_NO_BEAM intentional RED (defect visible)\n");
        delete t;
        return 2; // red twin exit — harness expects non-zero
    }
    delete t;
    return 1;
#else
    std::fprintf(stderr, "=== PRODUCT PRESENT_BEAM_960 hierarchy ===\n");
    std::fprintf(stderr,
                 "product: win=%u geom=%u cw=%u ch=%u coded=%ux%u yst=%u cst=%u "
                 "de=%ux%u ar=%u/%u\n",
                 t->obs_win_en, t->obs_geom_en, t->obs_content_w, t->obs_content_h,
                 t->obs_coded_w, t->obs_coded_h, t->obs_y_stride, t->obs_c_stride,
                 t->obs_win_h_de, t->obs_win_v_de, t->obs_video_arx, t->obs_video_ary);

    if (!t->obs_win_en)
        fail("product: win_enable=0 under PRESENT_BEAM_960");
    if (!t->obs_geom_en)
        fail("product: geom_enable=0 under PRESENT_BEAM_960");
    if (t->obs_content_w != 960 || t->obs_content_h != 540)
        fail("product: content not 960×540");
    if (t->obs_coded_w != 960 || t->obs_coded_h != 540)
        fail("product: geom coded not 960×540 (storage)");
    if (t->obs_y_stride != 960)
        fail("product: y_stride not 960 (storage, not canvas 1280)");
    if (t->obs_c_stride != 480)
        fail("product: chroma_stride not 480");
    if (t->obs_win_h_de != 960 || t->obs_win_v_de != 540)
        fail("product: win DE not 960×540 true-DE");
    // Top-level AR pins (Plex.sv VIDEO_ARX/VIDEO_ARY under PRESENT_BEAM_960).
    if (t->obs_video_arx != 0 || t->obs_video_ary != 0)
        fail("product: VIDEO_ARX/VIDEO_ARY not Full Screen 0/0 under beam");
    std::fprintf(stderr, "VIDEO_ARX=%u VIDEO_ARY=%u (FS)\n", t->obs_video_arx,
                 t->obs_video_ary);

    // U plane base for 960×540 = 960*540 = 518400 (B3 storage)
    const uint32_t u_base = (uint32_t)t->obs_y_stride * (uint32_t)t->obs_coded_h;
    if (u_base != 518400u)
        fail("product: U base != 518400 (canvas conflation?)");
    std::fprintf(stderr, "product U_base=%u (expect 518400)\n", u_base);

    // Run enough cycles for beam to toggle
    int saw_de = 0;
    for (int i = 0; i < 5000; ++i) {
        tick(t);
        if (t->obs_ce_pix && !t->obs_hblank && !t->obs_vblank)
            saw_de++;
    }
    if (saw_de < 100)
        fail("product: beam produced too few DE samples");
    std::fprintf(stderr, "product DE samples=%d\n", saw_de);

    // --- Option-C still selects for 1280 payload (capacity path via inject) ---
    // When beam force is on, inject is overridden — prove force wins over 1280 inject.
    t->inject_plxg_live = 1;
    t->inject_cw = 1280;
    t->inject_ch = 720;
    t->inject_coded_w = 1280;
    t->inject_coded_h = 720;
    t->inject_y_stride = 1280;
    t->inject_c_stride = 640;
    for (int i = 0; i < 8; ++i)
        tick(t);
    std::fprintf(stderr,
                 "1280-inject under beam: cw=%u coded=%u (must stay 960 — force wins)\n",
                 t->obs_content_w, t->obs_coded_w);
    if (t->obs_content_w != 960 || t->obs_coded_w != 960)
        fail("product: 1280 inject overrode PRESENT_BEAM_960 force");

    // Capacity arithmetic oracle (host-side of Option-C): 1280×720 I420 > usable
    const uint32_t payload_1280 =
        1280u * 720u + 2u * ((1280u / 2u) * (720u / 2u));
    const uint32_t usable = 0x7F000u; // 520192
    if (!(payload_1280 > usable))
        fail("oracle: 1280 payload should exceed legacy usable");
    std::fprintf(stderr,
                 "Option-C capacity: payload1280=%u usable=%u need_optc=1\n",
                 payload_1280, usable);
    // 960 payload also needs Option-C
    const uint32_t payload_960 = 960u * 540u + 2u * (480u * 270u);
    if (!(payload_960 > usable))
        fail("oracle: 960×540 payload must exceed usable (Option-C)");
    std::fprintf(stderr, "Option-C capacity: payload960=%u need_optc=1\n", payload_960);

    if (fails) {
        std::fprintf(stderr, "plex_b8_hier FAIL count=%d\n", fails);
        delete t;
        return 1;
    }
    std::fprintf(stderr, "plex_b8_hier ALL PASS\n");
    delete t;
    return 0;
#endif
}
