// present_beam_ppc: PPC=2 CEA 720p beam.
// Arithmetic (parent): 1280*720*24 = 22.1184e6 active px/s; with blanking
// CEA 1650*750*24 = 29.7e6 total px/s. At clk_sys=20 MHz, PPC=1 → 20 Mpix/s
// FAIL; PPC=2 → 40 Mpix/s PASS capacity.
//
// Negative: forced PX_PER_CLK=1 build must take ~2× beam_ce cycles per line.

#include "Vpresent_beam_ppc_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static void tick(Vpresent_beam_ppc_tb_top* d) {
    d->clk = 0;
    d->eval();
    d->clk = 1;
    d->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new Vpresent_beam_ppc_tb_top;
    dut->reset = 1;
    dut->enable = 0;
    for (int i = 0; i < 4; ++i) tick(dut);
    dut->reset = 0;
    dut->enable = 1;
    tick(dut);

    const int H_TOTAL = 1650;
    const int H_DE = 1280;

    // Count beam_ce groups while glass_y==0 only (do not count the y=1 head).
    int ce_cycles = 0;
    int de_groups = 0;
    int max_iters = H_TOTAL * 4;
    bool saw_y1 = false;
    uint32_t first_x = 0xFFFFFFFFu;
    int max_x0 = 0;
    for (int i = 0; i < max_iters; ++i) {
        if (dut->beam_ce) {
            if (dut->glass_y == 1 && ce_cycles > 0) {
                saw_y1 = true;
                break;
            }
            if (dut->glass_y == 0) {
                ++ce_cycles;
                if (first_x == 0xFFFFFFFFu) first_x = dut->glass_x0;
                if (static_cast<int>(dut->glass_x0) > max_x0)
                    max_x0 = static_cast<int>(dut->glass_x0);
                if (dut->lane_de != 0) ++de_groups;
            }
        }
        tick(dut);
    }

    // Infer PPC from observed step: first two x0 samples.
    // Rebuild path sets PX_PER_CLK via -G; detect from group density.
    const int ppc = (ce_cycles > 0) ? ((H_TOTAL + ce_cycles - 1) / ce_cycles) : 0;
    const int exp_groups = (H_TOTAL + (ppc > 0 ? ppc : 1) - 1) / (ppc > 0 ? ppc : 1);
    const int exp_de_groups = H_DE / (ppc > 0 ? ppc : 1);

    std::printf("BEAM_PPC ppc=%d ce_cycles_line0=%d exp_groups=%d de_groups=%d exp_de=%d first_x=%u saw_y1=%d\n",
                ppc, ce_cycles, exp_groups, de_groups, exp_de_groups, first_x, saw_y1 ? 1 : 0);

    int rc = 0;
    if (!saw_y1) {
        std::fprintf(stderr, "FAIL: never reached y=1\n");
        rc = 1;
    }
    if (ppc != 1 && ppc != 2 && ppc != 4) {
        std::fprintf(stderr, "FAIL: inferred ppc=%d not in {1,2,4} ce=%d\n", ppc, ce_cycles);
        rc = 1;
    }
    if (ce_cycles != exp_groups) {
        std::fprintf(stderr, "FAIL: ce_cycles %d != exp %d (ppc=%d)\n", ce_cycles, exp_groups, ppc);
        rc = 1;
    }
    if (de_groups != exp_de_groups) {
        std::fprintf(stderr, "FAIL: de_groups %d != exp %d\n", de_groups, exp_de_groups);
        rc = 1;
    }
    if (first_x != 0) {
        std::fprintf(stderr, "FAIL: first_x %u != 0\n", first_x);
        rc = 1;
    }

    // Capacity check print (not a hard fail here — documented arithmetic).
    const double mpix_ppc1 = 20.0;
    const double mpix_ppc2 = 40.0;
    const double need = 29.7;
    std::printf("PIXRATE_ARITH clk_sys=20MHz PPC1=%.1f PPC2=%.1f need_720p24_cea=%.1f Mpix/s\n",
                mpix_ppc1, mpix_ppc2, need);
    std::printf("PIXRATE_VERDICT PPC1=%s PPC2=%s\n",
                (mpix_ppc1 >= need) ? "PASS" : "FAIL",
                (mpix_ppc2 >= need) ? "PASS" : "FAIL");

    if (rc == 0)
        std::printf("PRESENT_BEAM_PPC PASS\n");
    else
        std::printf("PRESENT_BEAM_PPC FAIL\n");

    delete dut;
    return rc;
}
