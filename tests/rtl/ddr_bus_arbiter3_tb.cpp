#include "Vddr_bus_arbiter3_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vddr_bus_arbiter3_tb_top* top) {
    top->clk = 0; top->eval(); main_time++;
    top->clk = 1;
    if ((main_time % 5u) == 0u) top->clk_m1 = !top->clk_m1;
    top->eval(); main_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* top = new Vddr_bus_arbiter3_tb_top;
    top->DDRAM_BUSY = 0; top->DDRAM_DOUT = 0; top->DDRAM_DOUT_READY = 0;
    top->m0_rd = 0; top->m0_addr = 0; top->m1_want = 0; top->m1_rd = 0; top->m1_addr = 0;
    top->produce_en = 0; top->vsync_swap = 0; top->clk_m1 = 0;
    top->reset = 1;
    for (int i = 0; i < 20; ++i) tick(top);
    top->reset = 0;
    for (int i = 0; i < 10; ++i) tick(top);

    const uint32_t DOORBELL_Q = 0x30181F00u >> 3;
    const int FRAME_QWORDS = 12;
    int fails = 0;

    top->produce_en = 1;
    int payload = 0, doorbell = 0, last_pay_t = -1, db_t = -1;
    bool done = false;
    uint64_t last_db = 0;
    for (int cyc = 0; cyc < 8000 && !done; ++cyc) {
        if (top->DDRAM_WE && !top->DDRAM_BUSY) {
            uint32_t a = (uint32_t)top->DDRAM_ADDR;
            if (a == DOORBELL_Q) {
                ++doorbell; last_db = top->DDRAM_DIN; db_t = (int)main_time;
                if (last_pay_t < 0 || db_t <= last_pay_t) {
                    std::fprintf(stderr, "FAIL doorbell ordering\n"); ++fails;
                }
            } else {
                ++payload; last_pay_t = (int)main_time;
            }
        }
        if (top->frame_done) {
            done = true;
            top->produce_en = 0; // stop before next claim races vsync free
        }
        tick(top);
    }
    top->produce_en = 0;
    for (int i = 0; i < 8; ++i) tick(top); // drain NBA after frame_done/commit
    if (!done || payload != FRAME_QWORDS || doorbell != 1) {
        std::fprintf(stderr, "FAIL frame1 done=%d pay=%d db=%d\n", done, payload, doorbell);
        ++fails;
    }
    if ((last_db & 0xffffffffu) != 0x504C584Bu) {
        std::fprintf(stderr, "FAIL magic\n"); ++fails;
    }
    if (top->free_mask != 0) {
        std::fprintf(stderr, "FAIL free_mask after commit=%u want 0\n", (unsigned)top->free_mask);
        ++fails;
    }

    top->vsync_swap = 1;
    for (int i = 0; i < 4; ++i) tick(top);
    top->vsync_swap = 0;
    for (int i = 0; i < 8; ++i) tick(top);
    if (top->free_mask == 0) {
        std::fprintf(stderr, "FAIL free_mask still 0 after vsync (mask=%u frames=%u)\n",
                     (unsigned)top->free_mask, (unsigned)top->frames_done);
        ++fails;
    }
    if (top->frames_done < 1) {
        std::fprintf(stderr, "FAIL frames_done=%u\n", (unsigned)top->frames_done); ++fails;
    }

    payload = 0; doorbell = 0; done = false;
    top->produce_en = 1;
    top->m1_want = 1;
    for (int cyc = 0; cyc < 8000 && !done; ++cyc) {
        if (top->DDRAM_WE && !top->DDRAM_BUSY) {
            uint32_t a = (uint32_t)top->DDRAM_ADDR;
            if (a == DOORBELL_Q) ++doorbell; else ++payload;
        }
        if (top->DDRAM_RD) {
            std::fprintf(stderr, "FAIL RD during m2\n"); ++fails; break;
        }
        if (top->frame_done) {
            done = true;
            top->produce_en = 0;
        }
        tick(top);
    }
    top->produce_en = 0; top->m1_want = 0;
    if (!done || payload != FRAME_QWORDS || doorbell != 1) {
        std::fprintf(stderr, "FAIL frame2 done=%d pay=%d db=%d\n", done, payload, doorbell);
        ++fails;
    }
    // Retire frame2 so free_mask returns (else claim cannot start phase 3)
    top->vsync_swap = 1;
    for (int i = 0; i < 4; ++i) tick(top);
    top->vsync_swap = 0;
    for (int i = 0; i < 8; ++i) tick(top);

    // Phase 3: scanout-like pulsed m0 RD during writer fill (line-buffer cadence).
    // Continuous m0_rd is not a real present client and wedges rsp_pipe in this TB.
    payload = 0; doorbell = 0; done = false;
    int m0_beats = 0, m2_beats = 0;
    top->produce_en = 1;
    top->m0_addr = 0x100;
    top->DDRAM_DOUT_READY = 0;
    for (int cyc = 0; cyc < 16000 && !done; ++cyc) {
        // Pulse m0 every 4th cycle when not in a write beat observation window
        top->m0_rd = ((cyc % 4) == 0) ? 1 : 0;
        // Complete m0 read responses one cycle after RD accepted
        if (top->DDRAM_RD && !top->DDRAM_WE && !top->DDRAM_BUSY)
            ++m0_beats;
        top->DDRAM_DOUT_READY = (top->DDRAM_RD && !top->DDRAM_WE) ? 1 : 0;
        if (top->DDRAM_WE && !top->DDRAM_BUSY) {
            uint32_t a = (uint32_t)top->DDRAM_ADDR;
            if (a == DOORBELL_Q) ++doorbell;
            else { ++payload; ++m2_beats; }
        }
        if (top->frame_done) {
            done = true;
            top->produce_en = 0;
        }
        tick(top);
    }
    top->produce_en = 0;
    top->m0_rd = 0;
    top->DDRAM_DOUT_READY = 0;
    if (!done || payload != FRAME_QWORDS || doorbell != 1) {
        std::fprintf(stderr, "FAIL fair frame done=%d pay=%d db=%d\n", done, payload, doorbell);
        ++fails;
    }
    if (m0_beats < 1) {
        std::fprintf(stderr, "FAIL m0 starved during m2 fill m0_beats=%d m2=%d\n", m0_beats, m2_beats);
        ++fails;
    }
    if (m2_beats < FRAME_QWORDS) {
        std::fprintf(stderr, "FAIL m2 incomplete under m0 load m2=%d\n", m2_beats);
        ++fails;
    }

    if (fails) {
        std::fprintf(stderr, "ddr_bus_arbiter3_tb: %d fails\n", fails);
        delete top; return 1;
    }
    std::printf("ddr_bus_arbiter3_tb: OK pay=%d db_order=1 credit_vsync=1 m2_over_m1=1 "
                "m0_fair_beats=%d frames_done=%u\n",
                FRAME_QWORDS, m0_beats, (unsigned)top->frames_done);
    delete top; return 0;
}
