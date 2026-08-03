#include "Vddr_m1_subarb_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddr_m1_subarb_tb_top* top) {
    top->clk = 0;
    top->eval();
    main_time++;
    top->clk = 1;
    top->eval();
    main_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* top = new Vddr_m1_subarb_tb_top;

    top->stream_enable = 0;
    top->reset = 1;
    for (int i = 0; i < 8; ++i)
        tick(top);
    top->reset = 0;
    top->stream_enable = 1;

    // Run long enough for: stream 9× WE telemetry + PLXG poll (POLL_DIV=4) +
    // q0..q4 + q0 re-read + commit.
    int fails = 0;
    bool saw_we9 = false;
    bool saw_commit = false;
    bool saw_q0 = false;
    for (int cyc = 0; cyc < 20000; ++cyc) {
        if (top->stream_we_count >= 9)
            saw_we9 = true;
        if (top->plxg_got_q0)
            saw_q0 = true;
        if (top->plxg_cnt_commit > 0 || top->plxg_commit_pulse)
            saw_commit = true;
        if (saw_we9 && saw_q0 && saw_commit)
            break;
        tick(top);
    }

    std::printf("subarb_tb we=%u plxg_rd=%u commit=%u torn=%u bad=%u last_seq=%u "
                "got_q0=%d grant=%u\n",
                (unsigned)top->stream_we_count, (unsigned)top->plxg_rd_count,
                (unsigned)top->plxg_cnt_commit, (unsigned)top->plxg_cnt_torn,
                (unsigned)top->plxg_cnt_bad, (unsigned)top->plxg_last_seq,
                (int)top->plxg_got_q0, (unsigned)top->grant);

    if (!saw_we9) {
        std::fprintf(stderr, "FAIL: stream reset telemetry did not complete 9 WEs (got %u)\n",
                     (unsigned)top->stream_we_count);
        ++fails;
    }
    if (!saw_q0) {
        std::fprintf(stderr, "FAIL: PLXG never received q0 response during/after stream WE\n");
        ++fails;
    }
    if (!saw_commit) {
        std::fprintf(stderr, "FAIL: PLXG poller never committed (deadlock class)\n");
        ++fails;
    }
    if (top->plxg_cnt_torn != 0) {
        std::fprintf(stderr, "FAIL: unexpected torn count %u\n", (unsigned)top->plxg_cnt_torn);
        ++fails;
    }
    if (top->plxg_last_seq != 1) {
        std::fprintf(stderr, "FAIL: last_seq=%u want 1\n", (unsigned)top->plxg_last_seq);
        ++fails;
    }

    // NEG twin: if outstanding stuck on WE, PLXG would never commit — already gated.
    if (fails) {
        std::fprintf(stderr, "ddr_m1_subarb_tb: %d fails\n", fails);
        delete top;
        return 1;
    }
    std::printf("ddr_m1_subarb_tb: OK (stream WE telemetry + PLXG q0/commit)\n");
    delete top;
    return 0;
}
