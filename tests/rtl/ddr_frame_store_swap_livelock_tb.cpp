#include "Vddr_frame_store_warm_reset_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
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

uint64_t pack8(uint8_t v) {
    uint64_t q = 0;
    for (int i = 0; i < 8; ++i)
        q |= static_cast<uint64_t>(v) << (i * 8);
    return q;
}

uint32_t doorbellHi(uint32_t seq, int bank) {
    return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
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
    int scanX = 0;
    int scanY = 0;

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
        for (int line = 0; line < kH / 2; ++line)
            for (int q = 0; q < kCQ; ++q) {
                mem[base + kUQBase + line * kCQ + q] = pack8(u);
                mem[base + kVQBase + line * kCQ + q] = pack8(v);
            }
    }

    void ringDoorbell(int bank, uint32_t seq) {
        mem[offQ(kDoorbellPhys)] = (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
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

    void videoTick() {
        top.rd_active = 1;
        top.rd_x = scanX;
        top.rd_y = scanY;
        top.vsync_pulse = (scanX == 0 && scanY == 0);
        tick();
        ++scanX;
        if (scanX == kW) {
            scanX = 0;
            ++scanY;
            if (scanY == kH)
                scanY = 0;
        }
    }

    void resetCore() {
        top.reset = 1;
        for (int i = 0; i < 8; ++i)
            tick();
        top.reset = 0;
        for (int i = 0; i < 4; ++i)
            tick();
    }

    bool waitForFrameCount(int minFrames, int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            videoTick();
            if (top.frames_done >= minFrames)
                return true;
        }
        return false;
    }

    void idleTick(bool vsync = false) {
        top.rd_active = 0;
        top.rd_x = 0;
        top.rd_y = kH - 1;
        top.vsync_pulse = vsync;
        tick();
    }

    bool waitForFrameCountStatic(int minFrames, int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            idleTick((i % (kW * kH)) == 0);
            if (top.frames_done >= minFrames)
                return true;
        }
        return false;
    }

    void sweepFullFrames(int frames) {
        const int ticks = frames * kW * kH;
        for (int i = 0; i < ticks; ++i)
            videoTick();
    }

    void settleBottomWindow() {
        for (int i = 0; i < 5000; ++i) {
            top.rd_active = 1;
            top.rd_x = i % kW;
            top.rd_y = kH - 8;
            top.vsync_pulse = 0;
            tick();
        }
    }

    bool traceFinalDoorbell(int targetFrames, int maxVsyncs) {
        int vsyncs = 0;
        int lastIdx = -1;
        int lastLine = -1;
        int changes = 0;
        std::cout << "Trace: final-doorbell prep target by vsync (no injection)\n";
        while (vsyncs < maxVsyncs) {
            for (int i = 0; i < kW * kH; ++i) {
                const bool atVsync = (i == 0);
                idleTick(atVsync);
                const int idx = top.debug_target_y_idx_prep;
                const int line = top.debug_target_y_prep;
                if (idx != lastIdx || line != lastLine) {
                    if (changes < 24) {
                        std::cout << "TraceEvent: cycle=" << cycle
                                  << " vsyncs=" << vsyncs
                                  << " frames_done=" << top.frames_done
                                  << " prep_base_idx=" << int(top.debug_prep_base_idx)
                                  << " target_y_idx_prep_c=" << idx
                                  << " target_y_prep_c=" << line
                                  << " swap_pending=" << int(top.swap_pending)
                                  << " pending_ready=" << int(top.debug_pending_ready) << "\n";
                    }
                    ++changes;
                    lastIdx = idx;
                    lastLine = line;
                }
                if (atVsync) {
                    ++vsyncs;
                    std::cout << "TraceVsync: n=" << vsyncs
                              << " cycle=" << cycle
                              << " frames_done=" << top.frames_done
                              << " disp_bank=" << int(top.debug_disp_bank)
                              << " pending_bank=" << int(top.debug_pending_bank)
                              << " swap_pending=" << int(top.swap_pending)
                              << " pending_ready=" << int(top.debug_pending_ready)
                              << " prep_base_idx=" << int(top.debug_prep_base_idx)
                              << " target_y_idx_prep_c=" << idx
                              << " target_y_prep_c=" << line << "\n";
                }
            }
        }
        return top.frames_done >= targetFrames;
    }
};

void require(bool ok, const char* msg) {
    if (!ok)
        throw std::runtime_error(msg);
}

void runNaturalSwapLivelockGate() {
    Sim sim;
    sim.fillFrame(0, 72);
    sim.fillFrame(1, 196);
    sim.resetCore();

    sim.ringDoorbell(0, 101);
    require(sim.waitForFrameCountStatic(1, 800000), "first doorbell bank0 did not present");
    sim.sweepFullFrames(2);
    sim.settleBottomWindow();
    std::cout << "Raw: after first full sweep frames_done=" << sim.top.frames_done
              << " disp_bank=" << int(sim.top.debug_disp_bank)
              << " prep_base_idx=" << int(sim.top.debug_prep_base_idx)
              << " cycle=" << sim.cycle << "\n";

    sim.ringDoorbell(1, 102);
    if (!sim.waitForFrameCountStatic(2, 800000)) {
        std::cout << "Raw: second doorbell timeout debug disp_bank=" << int(sim.top.debug_disp_bank)
                  << " pending_bank=" << int(sim.top.debug_pending_bank)
                  << " swap_pending=" << int(sim.top.swap_pending)
                  << " pending_ready=" << int(sim.top.debug_pending_ready)
                  << " prep_base_idx=" << int(sim.top.debug_prep_base_idx)
                  << " target_y_idx_prep_c=" << int(sim.top.debug_target_y_idx_prep)
                  << " target_y_prep_c=" << int(sim.top.debug_target_y_prep)
                  << " need_y_prep=" << int(sim.top.debug_need_y_prep)
                  << " target_c_idx_prep_c=" << int(sim.top.debug_target_c_idx_prep)
                  << " target_c_prep_c=" << int(sim.top.debug_target_c_prep)
                  << " need_c_prep=" << int(sim.top.debug_need_c_prep)
                  << " doorbell_ok=" << int(sim.top.doorbell_ok)
                  << " debug_state=0x" << std::hex << int(sim.top.debug_state)
                  << std::dec << " DDRAM_RD=" << int(sim.top.DDRAM_RD)
                  << " DDRAM_BUSY=" << int(sim.top.DDRAM_BUSY)
                  << " DDRAM_BURSTCNT=" << int(sim.top.DDRAM_BURSTCNT)
                  << " sim_busy=" << sim.busy
                  << " sim_rdDelay=" << sim.rdDelay
                  << " sim_rdLeft=" << sim.rdLeft
                  << " cycle=" << sim.cycle << "\n";
        require(false, "second doorbell bank1 did not present");
    }
    sim.sweepFullFrames(2);
    sim.settleBottomWindow();
    std::cout << "Raw: after second full sweep frames_done=" << sim.top.frames_done
              << " disp_bank=" << int(sim.top.debug_disp_bank)
              << " prep_base_idx=" << int(sim.top.debug_prep_base_idx)
              << " cycle=" << sim.cycle << "\n";

    const int framesBeforeThird = sim.top.frames_done;
    sim.ringDoorbell(0, 103);
    const bool thirdSwap = sim.traceFinalDoorbell(framesBeforeThird + 1, 20);
    std::cout << "Raw: final assertion operands top.frames_done=" << sim.top.frames_done
              << " frames_before_third_plus_one=" << (framesBeforeThird + 1)
              << " swap_pending=" << int(sim.top.swap_pending)
              << " pending_ready=" << int(sim.top.debug_pending_ready)
              << " cycle=" << sim.cycle << "\n";
    if (!thirdSwap) {
        std::cerr << "FAIL ddr_frame_store swap-livelock natural: no third swap; "
                  << "assertion top.frames_done >= frames_before_third + 1 failed\n";
        std::exit(1);
    }
    std::cout << "OK ddr_frame_store swap-livelock natural: third doorbell swapped without injection\n";
}
} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "Scope: ddr_frame_store natural frame-store swap livelock; cold reset, doorbells 0->1->0, full rd_y sweeps, no hierarchical y_valid/y_bank/y_line injection.\n";
    std::cout << "Audit: assertion compares top.frames_done after final doorbell against frames_before_third + 1; it does not cover pixel color correctness, ARM timeout timing, or injected stale-state recovery.\n";
    try {
        runNaturalSwapLivelockGate();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL ddr_frame_store swap-livelock natural: " << e.what() << "\n";
        return 1;
    }
}
