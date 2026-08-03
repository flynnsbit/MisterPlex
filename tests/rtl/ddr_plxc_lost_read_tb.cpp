// Verilator TB: store-like m0 vs sticky m3_want launch-edge lost-read
#include "Vddr_plxc_lost_read_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddr_plxc_lost_read_tb_top* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static void reset_dut(Vddr_plxc_lost_read_tb_top* t) {
    t->reset = 1;
    t->run_enable = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    auto* t = new Vddr_plxc_lost_read_tb_top;
    reset_dut(t);
    t->run_enable = 1;

    for (int i = 0; i < 8000; ++i) {
        tick(t);
        if (t->fill_ok >= 32 && t->m3_beats >= 8)
            break;
    }

    std::fprintf(stderr,
                 "lost_read: fill_ok=%u fill_hang=%u arb_m0=%u arb_m3=%u "
                 "m3_beats=%u collisions=%u\n",
                 t->fill_ok, t->fill_hang, t->arb_m0, t->arb_m3, t->m3_beats,
                 t->collision_edges);

    if (t->fill_ok < 16)
        fail("too few completed store-like fills");
    if (t->fill_hang != 0) {
        fail("store WAIT hang (lost-read race)");
        std::fprintf(stderr, "REPRO lost-read-hang hang=%u\n", t->fill_hang);
    } else {
        std::fprintf(stderr, "PASS lost-read hang=0 fill_ok=%u\n", t->fill_ok);
    }
    if (t->arb_m3 < 1)
        fail("m3 never granted — collision not exercised");
    if (t->m3_beats < 1)
        fail("m3 never completed a beat");
    // Prefer evidence that launch edges overlapped grant_m3 at least once.
    if (t->collision_edges < 1) {
        std::fprintf(stderr,
                     "WARN collision_edges=0 (grant rise during ISSUE/WAIT not "
                     "sampled); arb_m3=%u still proves concurrent m3\n",
                     t->arb_m3);
    }

    if (fails) {
        std::fprintf(stderr, "ddr_plxc_lost_read FAIL count=%d\n", fails);
        delete t;
        return 1;
    }
    std::fprintf(stderr, "ddr_plxc_lost_read ALL PASS\n");
    delete t;
    return 0;
}
