// Verilator TB: per-request conservation under m0 vs m1/m3 collisions
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

    for (int i = 0; i < 60000; ++i) {
        tick(t);
        if (t->m3_hang != 0 || t->m1_hang != 0 || t->fill_hang != 0)
            break;
        if (t->fill_ok >= 20 && t->m3_done_total >= 16 && t->m1_done_total >= 8 &&
            t->coll_m0_m3_rd >= 1 && t->coll_m0_m3_we >= 1 &&
            t->collision_m0_m1 >= 1 && t->coll_complete_m3 >= 1 &&
            t->m3_done_total == t->m3_req_total &&
            t->m1_done_total == t->m1_req_total)
            break;
    }

    // Drain: stop new stimulus, let in-flight finish (product) or hang (fault).
    t->run_enable = 0;
    for (int i = 0; i < 4000; ++i) {
        tick(t);
        if (t->m3_hang != 0 || t->m1_hang != 0 || t->fill_hang != 0)
            break;
        if (t->m3_done_total == t->m3_req_total &&
            t->m1_done_total == t->m1_req_total)
            break;
    }

    std::fprintf(stderr,
                 "lost_read: fill_ok=%u fill_hang=%u arb_m0=%u arb_m1=%u arb_m3=%u "
                 "m1_done=%u/%u m3_done=%u/%u m1_hang=%u m3_hang=%u "
                 "coll_m0m3=%u (rd=%u we=%u) coll_m0m1=%u "
                 "coll_complete_m3=%u coll_lost_m3=%u m3_lost=%u m1_lost=%u\n",
                 t->fill_ok, t->fill_hang, t->arb_m0, t->arb_m1, t->arb_m3,
                 t->m1_done_total, t->m1_req_total, t->m3_done_total, t->m3_req_total,
                 t->m1_hang, t->m3_hang, t->collision_m0_m3, t->coll_m0_m3_rd,
                 t->coll_m0_m3_we, t->collision_m0_m1, t->coll_complete_m3,
                 t->coll_lost_m3, t->m3_lost_ids, t->m1_lost_ids);

    const bool any_hang =
        t->fill_hang != 0 || t->m1_hang != 0 || t->m3_hang != 0;

    if (any_hang) {
        std::fprintf(stderr,
                     "REPRO hang fill=%u m1=%u m3=%u coll_lost_m3=%u\n",
                     t->fill_hang, t->m1_hang, t->m3_hang, t->coll_lost_m3);
        fail("hang nonzero");
    } else {
        if (t->fill_ok < 12)
            fail("too few completed store-like fills");
        if (t->m3_req_total < 8)
            fail("too few m3 requests issued");
        if (t->m3_done_total != t->m3_req_total)
            fail("m3 request conservation broken (done != req)");
        if (t->m3_lost_ids != 0)
            fail("m3 lost request IDs nonzero on product");
        if (t->m1_req_total < 4)
            fail("too few m1 requests");
        if (t->m1_done_total != t->m1_req_total)
            fail("m1 request conservation broken");
        if (t->m1_lost_ids != 0)
            fail("m1 lost request IDs nonzero on product");
        if (t->coll_m0_m3_rd < 1)
            fail("no exact m0_rd&m3_rd collision");
        if (t->coll_m0_m3_we < 1)
            fail("no exact m0_rd&m3_we collision");
        if (t->collision_m0_m1 < 1)
            fail("no exact m0_rd&m1_rd collision");
        if (t->coll_complete_m3 < 1)
            fail("no collided m3 request completed (conservation after collision)");
        if (t->coll_lost_m3 != 0)
            fail("product lost a collided m3 request");
        std::fprintf(stderr,
                     "PASS conservation fill_ok=%u m3_done=%u/%u m1_done=%u/%u "
                     "coll_rd=%u coll_we=%u coll_m1=%u coll_complete_m3=%u\n",
                     t->fill_ok, t->m3_done_total, t->m3_req_total, t->m1_done_total,
                     t->m1_req_total, t->coll_m0_m3_rd, t->coll_m0_m3_we,
                     t->collision_m0_m1, t->coll_complete_m3);
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
