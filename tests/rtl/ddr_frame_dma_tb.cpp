// Verilator TB: ddr_frame_dma — legal Avalon burst + randomized waitrequest.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "Vddr_frame_dma.h"
#include "verilated.h"

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vddr_frame_dma* top = new Vddr_frame_dma;

    const uint32_t kQwords = 64;
    const uint32_t kBytes = kQwords * 8;
    const uint32_t kSrc = 0x1000;
    const uint32_t kDst = 0x8000;

    std::vector<uint64_t> mem(0x20000 / 8, 0);
    for (uint32_t i = 0; i < kQwords; i++)
        mem[(kSrc / 8) + i] = 0xA5A5000000000000ULL ^ i;

    auto tick = [&]() {
        top->clk = 0; top->eval(); main_time++;
        top->clk = 1; top->eval(); main_time++;
    };

    int rd_left = 0;
    uint32_t rd_addr = 0;
    int wr_left = 0;
    uint32_t wr_addr = 0;
    uint32_t wr_addr_lat = 0;
    uint8_t wr_bc_lat = 0;
    int proto_fail = 0;
    uint32_t lfsr = 0xACE1u;
    int use_rand_busy = 1;

    auto next_busy = [&]() -> uint8_t {
        if (!use_rand_busy) return 0;
        lfsr = (lfsr >> 1) ^ (uint32_t)(-(int)(lfsr & 1u) & 0xB400u);
        return (lfsr & 7u) == 0u;
    };

    // Drive BUSY/DOUT for the upcoming edge; after tick, retire accepts.
    auto cycle = [&]() {
        uint8_t busy = next_busy();
        top->DDRAM_BUSY = busy;
        top->DDRAM_DOUT_READY = 0;

        // Read data pipeline: provide beat when not busy and pending.
        if (rd_left > 0 && !busy) {
            top->DDRAM_DOUT = mem[rd_addr];
            top->DDRAM_DOUT_READY = 1;
        }

        tick();

        // Post-edge: command/data accepts use the busy we drove this edge.
        if (rd_left > 0 && !busy && top->DDRAM_DOUT_READY) {
            rd_addr++;
            rd_left--;
        } else if (wr_left > 0) {
            if (!top->DDRAM_WE) {
                std::fprintf(stderr, "FAIL proto: WE dropped mid-burst left=%d\n", wr_left);
                proto_fail = 1;
            } else if (top->DDRAM_ADDR != wr_addr_lat ||
                       top->DDRAM_BURSTCNT != wr_bc_lat) {
                std::fprintf(stderr,
                    "FAIL proto: ADDR/BC mut mid-burst a=%x/%x bc=%u/%u\n",
                    (unsigned)top->DDRAM_ADDR, wr_addr_lat,
                    (unsigned)top->DDRAM_BURSTCNT, (unsigned)wr_bc_lat);
                proto_fail = 1;
            } else if (!busy) {
                mem[wr_addr] = top->DDRAM_DIN;
                wr_addr++;
                wr_left--;
            }
        } else if (!busy && top->DDRAM_RD) {
            rd_addr = top->DDRAM_ADDR;
            rd_left = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1;
            // First data beat next cycles via rd_left path.
        } else if (!busy && top->DDRAM_WE) {
            wr_addr_lat = top->DDRAM_ADDR;
            wr_bc_lat = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1;
            wr_addr = wr_addr_lat;
            wr_left = wr_bc_lat;
            mem[wr_addr] = top->DDRAM_DIN;
            wr_addr++;
            wr_left--;
        }
    };

    top->reset = 1;
    top->start = 0;
    top->src_phys = kSrc;
    top->bank_phys = kDst;
    top->frame_bytes = kBytes;
    top->DDRAM_BUSY = 0;
    top->DDRAM_DOUT = 0;
    top->DDRAM_DOUT_READY = 0;
    use_rand_busy = 0;
    for (int i = 0; i < 4; i++) tick();
    top->reset = 0;
    tick();

    // G0 deterministic
    top->start = 1;
    cycle();
    top->start = 0;

    int guard = 200000;
    while (guard-- > 0) {
        cycle();
        if (proto_fail) return 1;
        if (top->done) break;
    }
    if (guard <= 0 || top->err_align ||
        top->rd_beats != kQwords || top->wr_beats != kQwords) {
        std::fprintf(stderr, "FAIL G0 timeout/beats rd=%u wr=%u busy=%d\n",
                     top->rd_beats, top->wr_beats, top->busy);
        return 1;
    }
    for (uint32_t i = 0; i < kQwords; i++) {
        uint64_t want = 0xA5A5000000000000ULL ^ i;
        if (mem[(kDst / 8) + i] != want) {
            std::fprintf(stderr, "FAIL G0 mem[%u]\n", i);
            return 1;
        }
    }

    // G0b random busy
    for (uint32_t i = 0; i < kQwords; i++) mem[(kDst / 8) + i] = 0;
    use_rand_busy = 1;
    top->reset = 1;
    for (int i = 0; i < 4; i++) tick();
    top->reset = 0;
    tick();
    top->src_phys = kSrc;
    top->bank_phys = kDst;
    top->frame_bytes = kBytes;
    top->start = 1;
    cycle();
    top->start = 0;
    rd_left = 0; wr_left = 0;
    guard = 400000;
    while (guard-- > 0) {
        cycle();
        if (proto_fail) return 1;
        if (top->done) break;
    }
    if (guard <= 0) {
        std::fprintf(stderr, "FAIL G0b timeout\n");
        return 1;
    }
    for (uint32_t i = 0; i < kQwords; i++) {
        uint64_t want = 0xA5A5000000000000ULL ^ i;
        if (mem[(kDst / 8) + i] != want) {
            std::fprintf(stderr, "FAIL G0b mem[%u] got=%016llx\n", i,
                         (unsigned long long)mem[(kDst / 8) + i]);
            return 1;
        }
    }

    // RED misalign
    use_rand_busy = 0;
    top->reset = 1;
    for (int i = 0; i < 4; i++) tick();
    top->reset = 0;
    tick();
    top->src_phys = kSrc + 1;
    top->start = 1;
    cycle();
    top->start = 0;
    guard = 50;
    while (guard-- > 0) {
        cycle();
        if (top->done) break;
    }
    if (!top->err_align) {
        std::fprintf(stderr, "FAIL expected err_align\n");
        return 1;
    }

    std::printf("PASS ddr_frame_dma_tb qwords=%u rand_busy=1 burst_mon=1 err_align_red=1\n",
                kQwords);
    delete top;
    return 0;
}
