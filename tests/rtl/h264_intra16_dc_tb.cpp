// Hand-computed H.264 DC prediction vectors (clauses 8.3.3.3 / 8.3.4.1).
// Every expected value below is derived by hand in the comment next to it; the
// point of this bench is the rounding, which a truncating divide gets wrong.
//
// Build + run:
//   ./scripts/run_verilator.sh --cc --exe --build \
//     --Mdir build/verilator/h264_intra16_dc \
//     --top-module h264_intra16_dc_tb_top -Wno-fatal -CFLAGS "-std=c++17 -O2" \
//     -o h264_intra16_dc_tb \
//     tests/rtl/h264_intra16_dc_tb_top.sv \
//     fpga/Plex_MiSTer/rtl/h264_intra16_dc.sv \
//     fpga/Plex_MiSTer/rtl/h264_intra_pred.sv \
//     tests/rtl/h264_intra16_dc_tb.cpp
//   ./build/verilator/h264_intra16_dc/h264_intra16_dc_tb
#include "Vh264_intra16_dc_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdio>
#include <string>

namespace {

Vh264_intra16_dc_tb_top* dut = nullptr;
int failures = 0;

void tick() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
}

void check(const std::string& what, int got, int want) {
    if (got != want) {
        std::printf("FAIL %s: got %d want %d\n", what.c_str(), got, want);
        ++failures;
    }
}

void run(const std::string& name,
         const std::array<int, 16>& above, const std::array<int, 16>& left,
         const std::array<int, 8>& c_above, const std::array<int, 8>& c_left,
         int has_above, int has_left,
         int want_luma_dc, int want_tl, int want_tr, int want_bl, int want_br) {
    for (int i = 0; i < 16; ++i) {
        dut->above[i] = static_cast<uint8_t>(above[i]);
        dut->left[i] = static_cast<uint8_t>(left[i]);
    }
    for (int i = 0; i < 8; ++i) {
        dut->c_above[i] = static_cast<uint8_t>(c_above[i]);
        dut->c_left[i] = static_cast<uint8_t>(c_left[i]);
    }
    dut->has_above = has_above;
    dut->has_left = has_left;

    dut->start = 1;
    tick();
    dut->start = 0;
    dut->eval();

    check(name + ".luma_valid", dut->luma_valid, 1);
    check(name + ".chroma_valid", dut->chroma_valid, 1);
    check(name + ".luma_dc", dut->luma_dc, want_luma_dc);
    check(name + ".chroma_dc_tl", dut->chroma_dc_tl, want_tl);
    check(name + ".chroma_dc_tr", dut->chroma_dc_tr, want_tr);
    check(name + ".chroma_dc_bl", dut->chroma_dc_bl, want_bl);
    check(name + ".chroma_dc_br", dut->chroma_dc_br, want_br);

    // Whole 16x16 block is the flat DC value.
    for (int i = 0; i < 256; ++i) {
        if (dut->luma_pred[i] != want_luma_dc) {
            check(name + ".luma_pred[" + std::to_string(i) + "]",
                  dut->luma_pred[i], want_luma_dc);
            break;
        }
    }
    // Chroma 8x8 is four 4x4 quadrants.
    for (int y = 0; y < 8; ++y) {
        for (int x = 0; x < 8; ++x) {
            const int want = (y < 4) ? ((x < 4) ? want_tl : want_tr)
                                     : ((x < 4) ? want_bl : want_br);
            if (dut->chroma_pred[y * 8 + x] != want) {
                check(name + ".chroma_pred[" + std::to_string(y * 8 + x) + "]",
                      dut->chroma_pred[y * 8 + x], want);
                y = 8;
                break;
            }
        }
    }

    // Cross-check: the DC path already shipping in h264_intra_pred.sv must agree.
    check(name + ".ref_luma_valid", dut->ref_luma_valid, 1);
    check(name + ".ref_chroma_valid", dut->ref_chroma_valid, 1);
    for (int i = 0; i < 256; ++i) {
        if (dut->ref_luma_pred[i] != dut->luma_pred[i]) {
            check(name + ".ref_luma_pred[" + std::to_string(i) + "]",
                  dut->ref_luma_pred[i], dut->luma_pred[i]);
            break;
        }
    }
    for (int i = 0; i < 64; ++i) {
        if (dut->ref_chroma_pred[i] != dut->chroma_pred[i]) {
            check(name + ".ref_chroma_pred[" + std::to_string(i) + "]",
                  dut->ref_chroma_pred[i], dut->chroma_pred[i]);
            break;
        }
    }
}

std::array<int, 16> fill16(int v) {
    std::array<int, 16> a{};
    a.fill(v);
    return a;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vh264_intra16_dc_tb_top;

    dut->reset = 1;
    dut->start = 0;
    tick();
    dut->reset = 0;

    // Chroma taps reused across cases:
    //   sa_lo = 1+1+2+2 = 6      sa_hi = 4*200 = 800
    //   sl_lo = 3+3+4+4 = 14     sl_hi = 4*100 = 400
    const std::array<int, 8> c_above = {1, 1, 2, 2, 200, 200, 200, 200};
    const std::array<int, 8> c_left = {3, 3, 4, 4, 100, 100, 100, 100};

    // Case 1: both neighbours available.
    //   luma: 16*10 + 16*11 = 336; (336 + 16) >> 5 = 352 >> 5 = 11
    //         (a truncating 336/32 = 10 would be wrong)
    //   chroma tl = (6 + 14 + 4) >> 3 = 24 >> 3 = 3   (trunc 20/8 = 2 wrong)
    //          tr = (800 + 2) >> 2 = 200
    //          bl = (400 + 2) >> 2 = 100
    //          br = (800 + 400 + 4) >> 3 = 1204 >> 3 = 150
    run("both", fill16(10), fill16(11), c_above, c_left, 1, 1, 11, 3, 200, 100, 150);

    // Case 2: only the top row available.
    //   luma above = 0..15, sum = 120; (120 + 8) >> 4 = 128 >> 4 = 8
    //         (a truncating 120/16 = 7 would be wrong)
    //   chroma tl = (6 + 2) >> 2 = 2, tr = (800 + 2) >> 2 = 200,
    //          bl falls back to the above samples = 2, br = 200
    std::array<int, 16> ramp{};
    for (int i = 0; i < 16; ++i) ramp[i] = i;
    run("top_only", ramp, fill16(255), c_above, c_left, 1, 0, 8, 2, 200, 2, 200);

    // Case 3: only the left column available.
    //   luma left = eight 9s then eight 10s, sum = 152; (152 + 8) >> 4 = 10
    //         (a truncating 152/16 = 9 would be wrong)
    //   chroma tl = (14 + 2) >> 2 = 4, tr falls back to left = 4,
    //          bl = (400 + 2) >> 2 = 100, br = 100
    std::array<int, 16> split{};
    for (int i = 0; i < 16; ++i) split[i] = (i < 8) ? 9 : 10;
    run("left_only", fill16(255), split, c_above, c_left, 0, 1, 10, 4, 4, 100, 100);

    // Case 4: neither neighbour available -> 1 << (BitDepth - 1).
    run("none", fill16(7), fill16(200), c_above, c_left, 0, 0, 128, 128, 128, 128, 128);

    // Saturation ends: all-255 must not overflow the sum, all-0 must stay 0.
    //   (32*255 + 16) >> 5 = 8176 >> 5 = 255
    run("all_max", fill16(255), fill16(255), {255, 255, 255, 255, 255, 255, 255, 255},
        {255, 255, 255, 255, 255, 255, 255, 255}, 1, 1, 255, 255, 255, 255, 255);
    run("all_zero", fill16(0), fill16(0), {0, 0, 0, 0, 0, 0, 0, 0},
        {0, 0, 0, 0, 0, 0, 0, 0}, 1, 1, 0, 0, 0, 0, 0);

    // valid must be a single-cycle pulse, not a level.
    tick();
    dut->eval();
    check("pulse.luma_valid", dut->luma_valid, 0);
    check("pulse.chroma_valid", dut->chroma_valid, 0);

    dut->final();
    delete dut;

    if (failures) {
        std::printf("h264_intra16_dc: %d FAILURES\n", failures);
        return 1;
    }
    std::printf("h264_intra16_dc: PASS (all four availability cases, luma + chroma)\n");
    return 0;
}
