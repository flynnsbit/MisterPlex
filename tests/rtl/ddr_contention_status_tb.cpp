// Self-checking TB for ddr_contention_status (w-plxd).
// POS: contended m0+m2 → stalls and m0_stall_while_m2 move up.
// NEG: idle bus → all stall counters stay 0 (naive "always increment" fails).
// NEG2: solo m0 free bus → accepts move, stalls stay 0.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vddr_contention_status_tb_top.h"
#include "verilated.h"

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddr_contention_status_tb_top* top) {
    top->clk = 0;
    top->eval();
    main_time += 1;
    top->clk = 1;
    top->eval();
    main_time += 1;
}

static void settle(Vddr_contention_status_tb_top* top, int n) {
    for (int i = 0; i < n; ++i)
        tick(top);
}

static void drive_idle(Vddr_contention_status_tb_top* top) {
    top->m0_busy = 0;
    top->m0_rd = 0;
    top->m0_we = 0;
    top->m0_dout_ready = 0;
    top->m2_busy = 0;
    top->m2_rd = 0;
    top->m2_we = 0;
    top->m2_dout_ready = 0;
    top->ddram_busy = 0;
    top->clear = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* top = new Vddr_contention_status_tb_top;

    std::printf("CASE EXECUTED ddr_contention_status_tb\n");
    std::printf("PREREG 720p24: payload 33177600 B/s/dir; FAIL if m0_stall_while_m2/window>=0.02\n");

    // Reset
    drive_idle(top);
    top->reset = 1;
    top->clear = 0;
    settle(top, 4);
    top->reset = 0;
    settle(top, 2);

    // ---------- NEG: idle — stalls must stay 0 ----------
    std::printf("CASE EXECUTED NEG_idle\n");
    drive_idle(top);
    settle(top, 40);
    const uint32_t win_idle = top->window_cycles;
    const uint32_t st0_idle = top->m0_stall_cycles;
    const uint32_t st2_idle = top->m2_stall_cycles;
    const uint32_t st02_idle = top->m0_stall_while_m2;
    const uint32_t acc0_idle = top->m0_cmd_accepts;
    std::printf("measured_neg_idle window=%u m0_stall=%u m2_stall=%u m0_st_m2=%u m0_acc=%u\n",
                win_idle, st0_idle, st2_idle, st02_idle, acc0_idle);
    if (win_idle < 30u) {
        std::printf("FAIL NEG_idle: window did not advance\n");
        return 1;
    }
    if (st0_idle != 0 || st2_idle != 0 || st02_idle != 0 || acc0_idle != 0) {
        std::printf("FAIL NEG_idle: stalls/accepts must stay 0 when no cmds "
                    "(naive always-count would fail here)\n");
        return 1;
    }
    std::printf("PASS NEG_idle\n");

    // Clear between cases
    top->clear = 1;
    settle(top, 2);
    top->clear = 0;
    settle(top, 2);

    // ---------- NEG2: solo m0 free bus — accepts, no stall ----------
    std::printf("CASE EXECUTED NEG_solo_m0_free\n");
    for (int i = 0; i < 20; ++i) {
        top->m0_busy = 0;
        top->m0_rd = 1;
        top->m0_we = 0;
        top->m0_dout_ready = (i % 2);
        top->m2_busy = 1;
        top->m2_rd = 0;
        top->m2_we = 0;
        top->ddram_busy = 0;
        tick(top);
    }
    drive_idle(top);
    settle(top, 4); // drain pipeline
    const uint32_t acc0_solo = top->m0_cmd_accepts;
    const uint32_t st0_solo = top->m0_stall_cycles;
    const uint32_t st02_solo = top->m0_stall_while_m2;
    const uint32_t rdb_solo = top->m0_rd_beats;
    std::printf("measured_neg_solo m0_acc=%u m0_stall=%u m0_st_m2=%u m0_rdb=%u\n",
                acc0_solo, st0_solo, st02_solo, rdb_solo);
    if (acc0_solo < 15u) {
        std::printf("FAIL NEG_solo: expected m0 accepts on free bus\n");
        return 1;
    }
    if (st0_solo != 0 || st02_solo != 0) {
        std::printf("FAIL NEG_solo: free-bus m0 must not stall "
                    "(false starvation would fail here)\n");
        return 1;
    }
    if (rdb_solo < 8u) {
        std::printf("FAIL NEG_solo: rd_beats should track dout_ready\n");
        return 1;
    }
    std::printf("PASS NEG_solo_m0_free\n");

    top->clear = 1;
    settle(top, 2);
    top->clear = 0;
    settle(top, 2);

    // ---------- POS: contended m0+m2 — m0 stalled while m2 cmds ----------
    std::printf("CASE EXECUTED POS_contended_m0_m2\n");
    // Model: arb holds m0 (busy=1, ddram_busy=0) while m2 also commands.
    for (int i = 0; i < 30; ++i) {
        top->ddram_busy = 0;
        top->m0_rd = 1;
        top->m0_we = 0;
        top->m0_busy = 1; // backpressured
        top->m0_dout_ready = 0;
        top->m2_rd = 0;
        top->m2_we = 1;
        top->m2_busy = 0; // m2 granted
        top->m2_dout_ready = 0;
        tick(top);
    }
    // A few m2 accepts then m0 gets bus
    for (int i = 0; i < 10; ++i) {
        top->m0_busy = 0;
        top->m0_rd = 1;
        top->m2_we = 0;
        top->m2_busy = 1;
        top->m0_dout_ready = 1;
        tick(top);
    }
    drive_idle(top);
    settle(top, 4);

    const uint32_t win_pos = top->window_cycles;
    const uint32_t st0_pos = top->m0_stall_cycles;
    const uint32_t st_arb = top->m0_stall_arb;
    const uint32_t st_ddr = top->m0_stall_ddr;
    const uint32_t st02_pos = top->m0_stall_while_m2;
    const uint32_t m2_acc = top->m2_cmd_accepts;
    const uint32_t m2_wra = top->m2_wr_accepts;
    const uint32_t m0_acc = top->m0_cmd_accepts;
    const uint64_t snap0 = top->snap_w0;
    const uint32_t magic = static_cast<uint32_t>(snap0 & 0xffffffffu);

    std::printf("measured_pos window=%u m0_stall=%u m0_st_arb=%u m0_st_ddr=%u "
                "m0_st_m2=%u m2_acc=%u m2_wra=%u m0_acc=%u magic=0x%08x\n",
                win_pos, st0_pos, st_arb, st_ddr, st02_pos, m2_acc, m2_wra, m0_acc, magic);

    if (magic != 0x504C5843u) {
        std::printf("FAIL POS: snap magic want PLXC 0x504C5843 got 0x%08x\n", magic);
        return 1;
    }
    if (st0_pos < 20u) {
        std::printf("FAIL POS: m0_stall_cycles did not observe backpressure\n");
        return 1;
    }
    if (st02_pos < 20u) {
        std::printf("FAIL POS: m0_stall_while_m2 must rise under dual-cmd contention\n");
        return 1;
    }
    if (st_arb < 20u || st_ddr != 0) {
        std::printf("FAIL POS: expected arb-hold stalls (ddram_busy=0), not DDR stalls\n");
        return 1;
    }
    if (m2_acc < 20u || m2_wra < 20u) {
        std::printf("FAIL POS: m2 accepts/wr must move while granted\n");
        return 1;
    }
    if (m0_acc < 5u) {
        std::printf("FAIL POS: m0 should accept after grant returns\n");
        return 1;
    }
    std::printf("PASS POS_contended_m0_m2\n");

    // ---------- POS2: DDR bridge busy attribution ----------
    std::printf("CASE EXECUTED POS_ddr_busy_attr\n");
    top->clear = 1;
    settle(top, 2);
    top->clear = 0;
    settle(top, 2);
    for (int i = 0; i < 15; ++i) {
        top->m0_rd = 1;
        top->m0_busy = 1;
        top->ddram_busy = 1; // bridge, not arb peer
        top->m2_rd = 0;
        top->m2_we = 0;
        top->m2_busy = 1;
        tick(top);
    }
    drive_idle(top);
    settle(top, 4);
    const uint32_t st_ddr2 = top->m0_stall_ddr;
    const uint32_t st_arb2 = top->m0_stall_arb;
    const uint32_t st02_2 = top->m0_stall_while_m2;
    std::printf("measured_pos_ddr m0_st_ddr=%u m0_st_arb=%u m0_st_m2=%u\n",
                st_ddr2, st_arb2, st02_2);
    if (st_ddr2 < 10u || st_arb2 != 0) {
        std::printf("FAIL POS_ddr: stalls must attribute to DDR not arb\n");
        return 1;
    }
    if (st02_2 != 0) {
        std::printf("FAIL POS_ddr: no m2 cmd → m0_stall_while_m2 must stay 0 "
                    "(must not blame publish for bridge busy)\n");
        return 1;
    }
    std::printf("PASS POS_ddr_busy_attr\n");

    std::printf("PASS ddr_contention_status_tb\n");
    delete top;
    return 0;
}
