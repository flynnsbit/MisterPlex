// Product q5 wire path: latch → plxg_* → plex_video_ar + plex_content_fps_sel.
// Green: commit+frame_boundary promote drives AR 16:9 and fps_eff=30.
// Red FAULT_DROP_LATCH_Q5: latch q5 not connected → must NOT get 16:9/30.
#include "Vplex_q5_product_wire_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

// Match present_geom_latch MAGIC_G = 32'h4758_4C50 ('PLXG' LE)
static constexpr uint32_t kMagic = 0x47584C50u;

static void tick(Vplex_q5_product_wire_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static uint64_t q0(uint32_t magic, bool win, bool geom, uint16_t epoch, uint16_t seq) {
    return uint64_t(magic) | (uint64_t(win) << 32) | (uint64_t(geom) << 33) |
           ((uint64_t(epoch) & 0x3fff) << 34) | (uint64_t(seq) << 48);
}

static uint64_t pack4x11(uint16_t a, uint16_t b, uint16_t c, uint16_t d) {
    return uint64_t(a & 0x7ff) | (uint64_t(b & 0x7ff) << 16) |
           (uint64_t(c & 0x7ff) << 32) | (uint64_t(d & 0x7ff) << 48);
}

static uint64_t pack_stride(uint16_t ys, uint16_t cs, uint16_t dw, uint16_t dh) {
    return uint64_t(ys & 0xfff) | (uint64_t(cs & 0x7ff) << 16) |
           (uint64_t(dw & 0x7ff) << 32) | (uint64_t(dh & 0x7ff) << 48);
}

static uint64_t pack_q5(uint16_t dar_x, uint16_t dar_y, uint8_t fps, bool dar_v, bool fps_v) {
    return uint64_t(dar_x & 0xfff) | (uint64_t(dar_y & 0xfff) << 12) |
           (uint64_t(fps) << 24) | (uint64_t(dar_v) << 32) | (uint64_t(fps_v) << 33);
}

static void writeQ(Vplex_q5_product_wire_tb* t, int idx, uint64_t data) {
    t->wr_en = 1;
    t->wr_idx = idx & 7;
    t->wr_data = data;
    t->commit = 0;
    t->frame_boundary = 0;
    tick(t);
    t->wr_en = 0;
    tick(t);
}

static void load_promote(Vplex_q5_product_wire_tb* t, uint16_t seq, uint64_t q5) {
    writeQ(t, 0, q0(kMagic, true, true, /*epoch=*/1, seq));
    writeQ(t, 1, pack4x11(960, 540, 0, 0));
    writeQ(t, 2, pack4x11(960, 540, 960, 540));
    writeQ(t, 3, pack_stride(960, 480, 960, 540));
    writeQ(t, 4, pack4x11(0, 0, 0, 0));
    writeQ(t, 5, q5);
    t->commit = 1;
    tick(t);
    t->commit = 0;
    tick(t);
    t->frame_boundary = 1;
    tick(t);
    t->frame_boundary = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* mode = std::getenv("Q5_WIRE_CASE");
    if (!mode)
        mode = "green";

    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    auto* t = new Vplex_q5_product_wire_tb;
    t->reset = 1;
    t->wr_en = 0;
    t->commit = 0;
    t->frame_boundary = 0;
    t->ar_menu = 0; // Original
    t->wr_idx = 0;
    t->wr_data = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 2; ++i)
        tick(t);

    std::fprintf(stderr, "EXECUTED %s\n", mode);

    const uint64_t q5_30 = pack_q5(16, 9, 30, true, true);
    load_promote(t, /*seq=*/1, q5_30);

    std::fprintf(stderr,
                 "after promote dar_v=%d dar_x=%u dar_y_via_ar ARX=%u ARY=%u "
                 "fps_v=%d fps_latched=%u c_fps_eff=%u\n",
                 (int)t->plxg_dar_valid_obs, (unsigned)t->plxg_dar_x_obs,
                 (unsigned)(t->VIDEO_ARX & 0xFFF), (unsigned)(t->VIDEO_ARY & 0xFFF),
                 (int)t->plxg_fps_valid_obs, (unsigned)t->plxg_content_fps_obs,
                 (unsigned)t->content_fps_eff);

    if (std::strcmp(mode, "green") == 0) {
        if (!t->plxg_dar_valid_obs)
            fail("dar_valid not promoted");
        if (t->plxg_dar_x_obs != 16)
            fail("dar_x want 16");
        if (!t->plxg_fps_valid_obs)
            fail("fps_valid not promoted");
        if (t->plxg_content_fps_obs != 30)
            fail("latched content_fps want 30");
        if ((t->VIDEO_ARX & 0xFFF) != 16)
            fail("VIDEO_ARX want 16 (host DAR)");
        if ((t->VIDEO_ARY & 0xFFF) != 9)
            fail("VIDEO_ARY want 9 (host DAR)");
        if (t->content_fps_eff != 30)
            fail("content_fps_eff want 30");
        if (fails == 0)
            std::fprintf(stderr, "PASS q5-wire-green\n");

        // Unspecified fps_valid=0 → film 24 (never invent 30)
        const uint64_t q5_nofps = pack_q5(16, 9, 30, true, false);
        load_promote(t, /*seq=*/2, q5_nofps);
        std::fprintf(stderr, "EXECUTED unspecified_fps c_fps_eff=%u\n",
                     (unsigned)t->content_fps_eff);
        if (t->content_fps_eff != 24)
            fail("unspecified fps want 24");
        else
            std::fprintf(stderr, "PASS unspecified_fps\n");
        // DAR still live 16:9
        if ((t->VIDEO_ARX & 0xFFF) != 16 || (t->VIDEO_ARY & 0xFFF) != 9)
            fail("DAR should remain 16:9 when only fps_valid clears");
        else
            std::fprintf(stderr, "PASS dar_holds_on_fps_clear\n");

        // dar_valid=0 → Original falls back 4:3 (deliberate)
        const uint64_t q5_nodar = pack_q5(16, 9, 24, false, true);
        load_promote(t, /*seq=*/3, q5_nodar);
        std::fprintf(stderr, "EXECUTED no_dar_fallback ARX=%u ARY=%u\n",
                     (unsigned)(t->VIDEO_ARX & 0xFFF), (unsigned)(t->VIDEO_ARY & 0xFFF));
        if ((t->VIDEO_ARX & 0xFFF) != 4 || (t->VIDEO_ARY & 0xFFF) != 3)
            fail("no dar_valid Original want legacy 4:3");
        else
            std::fprintf(stderr, "PASS no_dar_fallback_4_3\n");
    } else if (std::strcmp(mode, "drop") == 0) {
        // Latch q5 disconnected: must not show product 16:9 + 30
        const bool got_dar =
            ((t->VIDEO_ARX & 0xFFF) == 16 && (t->VIDEO_ARY & 0xFFF) == 9);
        const bool got_fps30 = (t->content_fps_eff == 30);
        if (got_dar)
            fail("drop twin still got host DAR 16:9 — q5 still connected");
        if (got_fps30)
            fail("drop twin still got fps 30 — q5 still connected");
        std::fprintf(stderr, "drop ARX=%u ARY=%u fps=%u (defect visible)\n",
                     (unsigned)(t->VIDEO_ARX & 0xFFF), (unsigned)(t->VIDEO_ARY & 0xFFF),
                     (unsigned)t->content_fps_eff);
        if (fails == 0)
            std::fprintf(stderr, "PASS q5-wire-drop\n");
    } else {
        fail("unknown Q5_WIRE_CASE");
    }

    if (fails) {
        std::fprintf(stderr, "plex_q5_product_wire_tb: %d FAIL(s)\n", fails);
        delete t;
        return 1;
    }
    std::fprintf(stderr, "plex_q5_product_wire_tb: PASS\n");
    delete t;
    return 0;
}
