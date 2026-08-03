// Verilator TB: m0 vs m1/m3 issued-cmd collision must not hang either side
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

    for (int i = 0; i < 30000; ++i) {
        tick(t);
        if (t->fill_ok >= 24 && t->m3_beats >= 12 && t->m1_beats >= 8 &&
            t->fill_hang == 0 && t->m1_hang == 0 && t->m3_hang == 0)
            break;
        // FAULT twin: exit once hang observed
        if (t->fill_hang != 0 || t->m1_hang != 0 || t->m3_hang != 0)
            break;
    }

    std::fprintf(stderr,
                 "lost_read: fill_ok=%u fill_hang=%u arb_m0=%u arb_m1=%u arb_m3=%u "
                 "m1_beats=%u m3_beats=%u m1_gnt=%u m3_gnt=%u "
                 "m1_hang=%u m3_hang=%u coll_m0m3=%u coll_m0m1=%u\n",
                 t->fill_ok, t->fill_hang, t->arb_m0, t->arb_m1, t->arb_m3,
                 t->m1_beats, t->m3_beats, t->m1_gnts, t->m3_gnts,
                 t->m1_hang, t->m3_hang, t->collision_m0_m3, t->collision_m0_m1);

    const bool any_hang =
        t->fill_hang != 0 || t->m1_hang != 0 || t->m3_hang != 0;

    if (any_hang) {
        std::fprintf(stderr,
                     "REPRO hang fill=%u m1=%u m3=%u\n",
                     t->fill_hang, t->m1_hang, t->m3_hang);
        // Binary fails on hang so product build is rc=1; shell FAULT treats as REPRO.
        fail("hang nonzero");
    } else {
        if (t->fill_ok < 12)
            fail("too few completed store-like fills");
        if (t->arb_m3 < 1)
            fail("m3 never granted");
        if (t->m3_beats < 4 || t->m3_gnts < 4)
            fail("m3 did not complete enough accept/beat pairs");
        if (t->m1_beats < 2 || t->m1_gnts < 2)
            fail("m1 did not complete enough accept/beat pairs");
        if (t->collision_m0_m3 < 1)
            fail("no exact m0_rd&m3_rd same-edge collision");
        if (t->collision_m0_m1 < 1)
            fail("no exact m0_rd&m1_rd same-edge collision");
        std::fprintf(stderr,
                     "PASS no-hang fill_ok=%u m1=%u m3=%u coll_m3=%u coll_m1=%u\n",
                     t->fill_ok, t->m1_beats, t->m3_beats, t->collision_m0_m3,
                     t->collision_m0_m1);
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
