// Verilator TB: PLXC chrome grant + video non-starve + starve red twin
#include "Vddr_plxc_grant_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddr_plxc_grant_tb_top* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static void mem_wr(Vddr_plxc_grant_tb_top* t, uint32_t byte_off, uint64_t data) {
    t->host_we = 1;
    t->host_addr = byte_off >> 3;
    t->host_wdata = data;
    tick(t);
    t->host_we = 0;
    tick(t);
}

static void reset_dut(Vddr_plxc_grant_tb_top* t, int starve) {
    t->reset = 1;
    t->starve_mode = starve ? 1 : 0;
    t->run_enable = 0;
    t->host_we = 0;
    t->host_addr = 0;
    t->host_wdata = 0;
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

    auto* t = new Vddr_plxc_grant_tb_top;

    // ========== PRODUCT arm: starve=0 ==========
    std::fprintf(stderr, "=== PRODUCT PLXC grant + concurrent video ===\n");
    reset_dut(t, 0);

    // Preload list[0] glyph + PLXC ctrl seq=7 count=1 enable
    const uint64_t g0 = (uint64_t)0x23 << 40 | (uint64_t)64 << 24 | (uint64_t)64 << 8 | 2ull;
    mem_wr(t, 0x140, g0);
    const uint64_t ctrl = 0x504C5843ull | (1ull << 32) | (1ull << 34) | (7ull << 48);
    mem_wr(t, 0x130, ctrl);

    t->run_enable = 1;

    uint32_t saw_gnt = 0;
    uint32_t saw_rd_valid = 0;
    for (int i = 0; i < 4000; ++i) {
        tick(t);
        if (t->plxc_m_gnt)
            saw_gnt++;
        if (t->plxc_m_rd_valid)
            saw_rd_valid++;
        // Enough evidence: chrome load complete + video traffic
        if (t->plxc_cnt_loads >= 1 && t->bridge_cnt_gnt >= 2 && t->video_rd_ok >= 16)
            break;
    }

    std::fprintf(stderr,
                 "product: loads=%u gnt_pulses=%u bridge_gnt=%u bridge_rd=%u bridge_we=%u "
                 "arb_m0=%u arb_m3=%u vid_ok=%u vid_underrun=%u max_lat=%u last_seq=%u\n",
                 t->plxc_cnt_loads, saw_gnt, t->bridge_cnt_gnt, t->bridge_cnt_rd,
                 t->bridge_cnt_we, t->arb_cnt_m0, t->arb_cnt_m3, t->video_rd_ok,
                 t->video_underrun, t->video_max_lat, t->plxc_last_seq);

    if (t->plxc_cnt_loads < 1)
        fail("product: chrome cnt_loads==0 (no grant path / no beats)");
    if (t->bridge_cnt_gnt < 1)
        fail("product: bridge_cnt_gnt==0 (m_gnt never asserted)");
    if (saw_gnt < 1)
        fail("product: observed plxc_m_gnt pulses==0");
    if (t->bridge_cnt_rd < 1)
        fail("product: bridge_cnt_rd==0 (no RD beats to chrome)");
    // PLXO WE should also flow
    if (t->bridge_cnt_we < 1 && t->plxc_cnt_plxo < 1)
        fail("product: no PLXO WE beats");
    if (t->plxc_last_seq != 7)
        fail("product: last_seq not 7");
    if (t->video_rd_ok < 8)
        fail("product: video path too few completed RDs");
    if (t->video_underrun != 0)
        fail("product: video underrun with concurrent chrome (starvation)");
    if (t->arb_cnt_m3 < 1)
        fail("product: arb cnt_grant_m3==0");

    if (fails == 0)
        std::fprintf(stderr, "PASS product grant+beats video_clear underrun=0 max_lat=%u\n",
                     t->video_max_lat);

    // ========== RED twin: starve=1 must produce underrun ==========
    std::fprintf(stderr, "=== RED TWIN starve_video=1 ===\n");
    reset_dut(t, 1);
    t->run_enable = 1;

    for (int i = 0; i < 2000; ++i) {
        tick(t);
        if (t->video_underrun >= 2)
            break;
    }

    std::fprintf(stderr,
                 "starve: vid_ok=%u vid_underrun=%u arb_m0=%u arb_m3=%u max_lat=%u\n",
                 t->video_rd_ok, t->video_underrun, t->arb_cnt_m0, t->arb_cnt_m3,
                 t->video_max_lat);

    if (t->video_underrun < 1) {
        fail("red-twin: expected video_underrun>=1 under starve_video");
        std::fprintf(stderr, "REPRO starve-underrun-absent underrun=%u\n", t->video_underrun);
    } else {
        std::fprintf(stderr, "REPRO starve-underrun underrun=%u\n", t->video_underrun);
        std::fprintf(stderr, "PASS red-twin underrun\n");
    }

    if (fails) {
        std::fprintf(stderr, "ddr_plxc_grant FAIL count=%d\n", fails);
        delete t;
        return 1;
    }
    std::fprintf(stderr, "ddr_plxc_grant ALL PASS\n");
    delete t;
    return 0;
}
