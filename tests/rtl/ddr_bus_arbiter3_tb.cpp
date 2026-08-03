// Verilator TB: fabric attach through ddr_bus_arbiter3 m2 must complete
// one I420 frame and ring doorbell AFTER the last payload beat.
#include "Vddr_bus_arbiter3_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <map>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddr_bus_arbiter3_tb_top* top) {
    top->clk = 0;
    top->eval();
    main_time++;
    top->clk = 1;
    if ((main_time % 5u) == 0u)
        top->clk_m1 = !top->clk_m1;
    top->eval();
    main_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* top = new Vddr_bus_arbiter3_tb_top;

    top->DDRAM_BUSY = 0;
    top->DDRAM_DOUT = 0;
    top->DDRAM_DOUT_READY = 0;
    top->m0_rd = 0;
    top->m0_addr = 0;
    top->m1_want = 0;
    top->m1_rd = 0;
    top->m1_addr = 0;
    top->start = 0;
    top->bank_id = 0;
    top->clk_m1 = 0;
    top->reset = 1;
    for (int i = 0; i < 20; ++i)
        tick(top);
    top->reset = 0;
    for (int i = 0; i < 10; ++i)
        tick(top);

    std::map<uint32_t, uint64_t> mem;
    int payload_we = 0;
    int doorbell_we = 0;
    uint64_t last_db = 0;
    int fails = 0;

    const uint32_t PHYS_Q = 0x30180000u >> 3;
    const uint32_t DOORBELL_Q = 0x30181F00u >> 3;
    const int FRAME_QWORDS = (8 * 8 * 3 / 2) / 8; // 12

    top->bank_id = 0;
    top->start = 1;
    tick(top);
    top->start = 0;

    bool saw_frame_done = false;
    int last_payload_time = -1;
    int doorbell_time = -1;

    for (int cyc = 0; cyc < 5000 && !saw_frame_done; ++cyc) {
        if (top->DDRAM_WE && !top->DDRAM_BUSY) {
            const uint32_t a = static_cast<uint32_t>(top->DDRAM_ADDR);
            const uint64_t d = top->DDRAM_DIN;
            mem[a] = d;
            if (a == DOORBELL_Q) {
                ++doorbell_we;
                last_db = d;
                doorbell_time = static_cast<int>(main_time);
                if (last_payload_time < 0 || doorbell_time <= last_payload_time) {
                    std::fprintf(stderr, "FAIL doorbell before/without payload complete\n");
                    ++fails;
                }
            } else {
                ++payload_we;
                last_payload_time = static_cast<int>(main_time);
            }
        }
        if (top->frame_done)
            saw_frame_done = true;
        tick(top);
    }

    if (!saw_frame_done) {
        std::fprintf(stderr, "FAIL no frame_done\n");
        ++fails;
    }
    if (payload_we != FRAME_QWORDS) {
        std::fprintf(stderr, "FAIL payload_we=%d want=%d\n", payload_we, FRAME_QWORDS);
        ++fails;
    }
    if (doorbell_we != 1) {
        std::fprintf(stderr, "FAIL doorbell_we=%d want=1\n", doorbell_we);
        ++fails;
    }
    if ((last_db & 0xFFFFFFFFu) != 0x504C584Bu) {
        std::fprintf(stderr, "FAIL doorbell magic=0x%08x\n",
                     static_cast<unsigned>(last_db & 0xFFFFFFFFu));
        ++fails;
    }
    for (int i = 0; i < FRAME_QWORDS; ++i) {
        if (mem.find(PHYS_Q + static_cast<uint32_t>(i)) == mem.end()) {
            std::fprintf(stderr, "FAIL missing payload qword %d\n", i);
            ++fails;
            break;
        }
    }

    // m2 priority over m1: hold m1_want, complete another full frame, no RD.
    for (int i = 0; i < 40; ++i)
        tick(top); // drain grants / want sync between frames
    payload_we = 0;
    doorbell_we = 0;
    saw_frame_done = false;
    top->m1_want = 1;
    top->m1_rd = 0;
    top->m0_rd = 0;
    for (int i = 0; i < 10; ++i)
        tick(top); // let m1_want sync; arbiter may grant_m1 then yield
    top->start = 1;
    tick(top);
    top->start = 0;
    for (int cyc = 0; cyc < 5000 && !saw_frame_done; ++cyc) {
        if (top->DDRAM_WE && !top->DDRAM_BUSY) {
            const uint32_t a = static_cast<uint32_t>(top->DDRAM_ADDR);
            if (a == DOORBELL_Q)
                ++doorbell_we;
            else
                ++payload_we;
        }
        if (top->DDRAM_RD) {
            std::fprintf(stderr, "FAIL unexpected RD during m2 frame\n");
            ++fails;
            break;
        }
        if (top->frame_done)
            saw_frame_done = true;
        tick(top);
    }
    top->m1_want = 0;
    if (!saw_frame_done || payload_we != FRAME_QWORDS || doorbell_we != 1) {
        std::fprintf(stderr, "FAIL m2-over-m1 done=%d payload=%d db=%d\n",
                     saw_frame_done ? 1 : 0, payload_we, doorbell_we);
        ++fails;
    }

    if (fails) {
        std::fprintf(stderr, "ddr_bus_arbiter3_tb: %d fails\n", fails);
        delete top;
        return 1;
    }
    std::printf("ddr_bus_arbiter3_tb: OK payload_qwords=%d doorbell=1 "
                "ordering=payload_then_db m2_over_m1=1\n",
                FRAME_QWORDS);
    delete top;
    return 0;
}
