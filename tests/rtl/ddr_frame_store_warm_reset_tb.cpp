#include "Vddr_frame_store_warm_reset_tb.h"
#include "verilated.h"

#include <cstdint>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 65536u;
constexpr uint32_t kDoorbellPhys = 0x3001F000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kW = 80;
constexpr int kH = 48;
constexpr int kYQ = kW / 8;
constexpr int kCQ = kW / 16;
constexpr int kUQBase = (kW * kH) / 8;
constexpr int kVQBase = kUQBase + (kW * kH) / 32;

uint32_t doorbellHi(uint32_t seq, int bank) {
    return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
    uint64_t q = 0;
    for (int i = 0; i < 8; ++i)
        q |= static_cast<uint64_t>(v) << (i * 8);
    return q;
}

uint8_t expectedRgb(uint8_t y) {
    return y;
}

class Sim {
public:
    Vddr_frame_store_warm_reset_tb top{};
    std::vector<uint64_t> mem;
    uint64_t cycle = 0;
    int busy = 0;
    int rdDelay = -1;
    uint32_t rdAddr = 0;
    int rdLeft = 0;
    int rdIndex = 0;

    Sim() : mem((2 * kBankStrideBytes) / 8, 0) {
        top.clk = 0;
        top.clk_ddr = 0;
        top.reset = 0;
        top.rd_x = 0;
        top.rd_y = 0;
        top.rd_active = 0;
        top.start_req = 0;
        top.bank_sel = 0;
        top.vsync_pulse = 0;
        top.DDRAM_BUSY = 0;
        top.DDRAM_DOUT = 0;
        top.DDRAM_DOUT_READY = 0;
    }

    uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
    uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

    void fillFrame(int bank, uint8_t y, uint8_t u = 128, uint8_t v = 128) {
        const uint32_t base = (bank * kBankStrideBytes) / 8;
        for (int line = 0; line < kH; ++line)
            for (int q = 0; q < kYQ; ++q)
                mem[base + line * kYQ + q] = pack8(y);
        for (int line = 0; line < kH / 2; ++line) {
            for (int q = 0; q < kCQ; ++q) {
                mem[base + kUQBase + line * kCQ + q] = pack8(u);
                mem[base + kVQBase + line * kCQ + q] = pack8(v);
            }
        }
    }

    void ringDoorbell(int bank, uint32_t seq) {
        const uint32_t off = offQ(kDoorbellPhys);
        mem[off] = static_cast<uint64_t>(doorbellHi(seq, bank)) << 32 | kMagic;
    }

    void serviceDdrStart() {
        if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
            rdAddr = top.DDRAM_ADDR;
            rdLeft = top.DDRAM_BURSTCNT;
            rdIndex = 0;
            rdDelay = 2;
            busy = rdLeft + rdDelay + 1;
        }
        if (top.DDRAM_WE && busy == 0) {
            const uint32_t off = addrOffQ(top.DDRAM_ADDR);
            if (off < mem.size())
                mem[off] = top.DDRAM_DIN;
            busy = 2;
        }
    }

    void serviceDdrDrive() {
        top.DDRAM_DOUT_READY = 0;
        if (busy > 0)
            --busy;
        top.DDRAM_BUSY = busy > 0;
        if (rdDelay >= 0) {
            if (rdDelay > 0) {
                --rdDelay;
            } else if (rdLeft > 0) {
                const uint32_t off = addrOffQ(rdAddr + rdIndex);
                top.DDRAM_DOUT = off < mem.size() ? mem[off] : 0;
                top.DDRAM_DOUT_READY = 1;
                ++rdIndex;
                --rdLeft;
                if (rdLeft == 0)
                    rdDelay = -1;
            }
        }
    }

    void tick() {
        top.clk = 0;
        top.clk_ddr = 0;
        top.eval();
        serviceDdrDrive();
        top.clk = 1;
        top.clk_ddr = 1;
        top.eval();
        serviceDdrStart();
        top.clk = 0;
        top.clk_ddr = 0;
        top.eval();
        ++cycle;
        top.vsync_pulse = 0;
    }

    void resetCore() {
        top.reset = 1;
        for (int i = 0; i < 8; ++i)
            tick();
        top.reset = 0;
        for (int i = 0; i < 4; ++i)
            tick();
    }

    void pulseVsync() {
        top.vsync_pulse = 1;
        tick();
    }

    bool waitCyclesNoFrame(int n) {
        for (int i = 0; i < n; ++i) {
            if ((i % 97) == 0)
                pulseVsync();
            else
                tick();
            if (top.has_frame)
                return false;
        }
        return true;
    }

    bool waitForFrame(int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            if ((i % 97) == 0)
                pulseVsync();
            else
                tick();
            if (top.has_frame)
                return true;
        }
        return false;
    }

    uint8_t sample(int x, int y) {
        top.rd_x = x;
        top.rd_y = y;
        top.rd_active = 1;
        for (int i = 0; i < 18; ++i)
            tick();
        top.rd_active = 0;
        tick();
        return top.rd_r;
    }
};

void run() {
    {
        Sim sim;
        sim.fillFrame(1, 208);
        sim.resetCore();
        for (int i = 0; i < 3000; ++i)
            sim.tick();
        sim.ringDoorbell(1, 1);
        if (!sim.waitForFrame(50000))
            throw std::runtime_error("first fresh doorbell without stale magic did not produce a frame");
        for (int i = 0; i < 1000; ++i)
            sim.tick();
        const uint8_t got = sim.sample(0, 0);
        if (got < 207 || got > 209) {
            std::cerr << "FAIL ddr_frame_store warm-reset: first fresh no-stale pixel r="
                      << int(got) << " want≈208\n";
            std::exit(1);
        }
    }

    Sim sim;
    sim.fillFrame(0, 48);
    sim.fillFrame(1, 208);
    sim.ringDoorbell(0, 1);
    sim.resetCore();

    if (!sim.waitCyclesNoFrame(25000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: accepted stale doorbell before fresh frame"
                  << " cycle=" << sim.cycle << " frames=" << sim.top.frames_done << "\n";
        std::exit(1);
    }

    sim.ringDoorbell(1, 2);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error("fresh doorbell did not produce a frame");
    for (int i = 0; i < 1000; ++i)
        sim.tick();

    const uint8_t got = sim.sample(0, 0);
    const uint8_t want = expectedRgb(208);
    if (got + 1 < want || got > want + 1) {
        std::cerr << "FAIL ddr_frame_store warm-reset: got stale/wrong pixel r=" << int(got)
                  << " want≈" << int(want) << " frames=" << sim.top.frames_done
                  << " underruns=" << sim.top.underrun_count
                  << " has_frame=" << int(sim.top.has_frame)
                  << " swap_pending=" << int(sim.top.swap_pending)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }

    std::cout << "ddr_frame_store warm-reset raw: stale_seq=1 fresh_seq=2 stale_bank=0"
              << " fresh_bank=1 first_fresh_no_stale=pass no_frame_cycles=25000 frames=" << sim.top.frames_done
              << " sample_x=0 sample_y=0 sample_r=" << int(got)
              << " underruns=" << sim.top.underrun_count
              << " cycles=" << sim.cycle << "\n";
    std::cout << "OK ddr_frame_store warm-reset: stale doorbell ignored until fresh frame\n";
}
} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        run();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL ddr_frame_store warm-reset: " << e.what() << "\n";
        return 1;
    }
}
