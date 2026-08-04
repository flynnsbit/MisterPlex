// Verilator TB: ddr_frame_dma copies N qwords src→dst on a simple DDR model.
// Proves rd_beats == wr_beats == N and memory contents match.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "Vddr_frame_dma.h"
#include "verilated.h"

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vddr_frame_dma* top = new Vddr_frame_dma;

    const uint32_t kQwords = 64;  // small frame for speed
    const uint32_t kBytes = kQwords * 8;
    const uint32_t kSrc = 0x1000;
    const uint32_t kDst = 0x8000;

    std::vector<uint64_t> mem(0x20000 / 8, 0);
    for (uint32_t i = 0; i < kQwords; i++) {
        mem[(kSrc / 8) + i] = 0xA5A5000000000000ULL ^ i;
    }

    auto tick = [&]() {
        top->clk = 0;
        top->eval();
        main_time++;
        top->clk = 1;
        top->eval();
        main_time++;
    };

    top->reset = 1;
    top->start = 0;
    top->src_phys = kSrc;
    top->bank_phys = kDst;
    top->frame_bytes = kBytes;
    top->DDRAM_BUSY = 0;
    top->DDRAM_DOUT = 0;
    top->DDRAM_DOUT_READY = 0;
    for (int i = 0; i < 4; i++) tick();
    top->reset = 0;
    tick();

    top->start = 1;
    tick();
    top->start = 0;

    int guard = 100000;
    uint8_t rd_pending = 0;
    uint32_t rd_addr = 0;
    uint8_t rd_left = 0;
    uint8_t wr_pending = 0;
    uint32_t wr_addr = 0;
    uint8_t wr_left = 0;

    while (guard-- > 0) {
        // Simple DDR: accept cmd when !BUSY; return data next cycle for RD
        top->DDRAM_DOUT_READY = 0;

        if (rd_pending && rd_left) {
            top->DDRAM_DOUT = mem[rd_addr];
            top->DDRAM_DOUT_READY = 1;
            rd_addr++;
            rd_left--;
            if (rd_left == 0) rd_pending = 0;
        } else if (top->DDRAM_RD && !top->DDRAM_BUSY) {
            rd_pending = 1;
            rd_addr = top->DDRAM_ADDR;
            rd_left = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1;
            // first beat same cycle after issue — model 1-cycle latency via next tick path
            // Provide first beat on this tick after eval of rising edge already done —
            // supply on next iteration.
        } else if (top->DDRAM_WE && !top->DDRAM_BUSY) {
            uint32_t a = top->DDRAM_ADDR;
            mem[a] = top->DDRAM_DIN;
            // multi-beat writes issued as BURSTCNT with subsequent BEATS as 1
            (void)wr_pending;
            (void)wr_addr;
            (void)wr_left;
        }

        tick();

        if (top->done) break;
    }

    if (guard <= 0) {
        std::fprintf(stderr, "FAIL timeout busy=%d rd=%u wr=%u\n",
                     top->busy, top->rd_beats, top->wr_beats);
        return 1;
    }
    if (top->err_align) {
        std::fprintf(stderr, "FAIL unexpected err_align\n");
        return 1;
    }
    if (top->rd_beats != kQwords || top->wr_beats != kQwords) {
        std::fprintf(stderr, "FAIL beats rd=%u wr=%u want=%u\n",
                     top->rd_beats, top->wr_beats, kQwords);
        return 1;
    }
    for (uint32_t i = 0; i < kQwords; i++) {
        uint64_t got = mem[(kDst / 8) + i];
        uint64_t want = 0xA5A5000000000000ULL ^ i;
        if (got != want) {
            std::fprintf(stderr, "FAIL mem[%u] got=%016llx want=%016llx\n",
                         i, (unsigned long long)got, (unsigned long long)want);
            return 1;
        }
    }

    // RED: misaligned start must set err_align
    top->reset = 1;
    for (int i = 0; i < 4; i++) tick();
    top->reset = 0;
    tick();
    top->src_phys = kSrc + 1;
    top->bank_phys = kDst;
    top->frame_bytes = kBytes;
    top->start = 1;
    tick();
    top->start = 0;
    guard = 100;
    while (guard-- > 0) {
        tick();
        if (top->done) break;
    }
    if (!top->err_align) {
        std::fprintf(stderr, "FAIL expected err_align on misaligned src\n");
        return 1;
    }

    std::printf("PASS ddr_frame_dma_tb qwords=%u rd=%u wr=%u err_align_red=1\n",
                kQwords, kQwords, kQwords);
    delete top;
    return 0;
}
