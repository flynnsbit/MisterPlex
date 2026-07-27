// disp_buf_d2 timing violation testbench driver.
//
// Tests whether the STA-reported violation on disp_buf_d2 → DDRAM_ADDR
// (slack -0.213 ns, 7 logic levels, 10.722 ns) can produce the frozen
// screen signature: has_frame=0 permanently after a bank swap.
//
// Mechanism: At the moment disp_buf_d2 toggles (bank swap propagation),
// hold it at the old value for 1 extra clk_ddr cycle, simulating the
// timing violation where downstream combinational logic sees stale data.
//
// Controlled by environment variables:
//   INJECT_BANK_GLITCH=1: enable glitch injection at swap time
//   HOLD_CYCLES=N: hold old disp_buf_d2 for N extra cycles (default 1)

#include "Vddr_frame_store_want_y_glitch_tb.h"
#include "Vddr_frame_store_want_y_glitch_tb___024root.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

class Sim {
public:
    Vddr_frame_store_want_y_glitch_tb top{};
    std::vector<uint64_t> mem;
    uint64_t cycle = 0;
    int busy = 0;
    int rdDelay = -1;
    uint32_t rdAddr = 0;
    int rdLeft = 0;
    int rdIndex = 0;
    int scanX = 0;
    int scanY = 0;

    // Bank glitch injection state
    bool injectBankGlitch = false;
    int holdCycles = 1;
    uint8_t prevDispBufD2 = 0;
    int glitchHoldRemaining = 0;
    int glitchCount = 0;

    // Counters
    int has_frame_cycles = 0;
    int no_frame_cycles = 0;
    int ddrReadBursts = 0;  // degeneracy: must be non-zero for a valid test

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
        uint32_t hi = (static_cast<uint32_t>(bank & 1) << 31) |
                      (static_cast<uint32_t>(1) << 29) | (seq & 0x1fffffffu);
        mem[off] = static_cast<uint64_t>(hi) << 32 | kMagic;
    }

    void serviceDdrStart() {
        if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
            ++ddrReadBursts;
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
        top.DDRAM_BUSY = (busy > 0);
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

    void injectBankSwapGlitch() {
        if (!injectBankGlitch) return;
        auto* r = top.rootp;
        uint8_t curBuf = r->ddr_frame_store_want_y_glitch_tb__DOT__dut__DOT__disp_buf_d2;

        if (glitchHoldRemaining > 0) {
            // Hold old value — simulates timing violation where
            // combinational logic sees stale disp_buf_d2
            r->ddr_frame_store_want_y_glitch_tb__DOT__dut__DOT__disp_buf_d2 = prevDispBufD2;
            --glitchHoldRemaining;
            ++glitchCount;
        } else if (curBuf != prevDispBufD2 && glitchCount == 0) {
            // disp_buf_d2 just toggled — ONE-SHOT: hold old value
            glitchHoldRemaining = holdCycles;
            r->ddr_frame_store_want_y_glitch_tb__DOT__dut__DOT__disp_buf_d2 = prevDispBufD2;
            ++glitchCount;
        } else {
            prevDispBufD2 = curBuf;
        }
    }

    void tick() {
        // Falling edge
        top.clk = 0;
        top.clk_ddr = 0;
        top.eval();
        serviceDdrDrive();
        // Inject bank glitch BEFORE rising edge
        injectBankSwapGlitch();
        // Rising edge
        top.clk = 1;
        top.clk_ddr = 1;
        top.eval();
        serviceDdrStart();
        // Settle
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
        if (top.has_frame)
            ++has_frame_cycles;
        else
            ++no_frame_cycles;
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

    bool waitForFrame(int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            videoTick();
            if (top.has_frame)
                return true;
        }
        return false;
    }
};

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Sim s;

    const char* env = std::getenv("INJECT_BANK_GLITCH");
    s.injectBankGlitch = env && std::string(env) == "1";
    const char* holdEnv = std::getenv("HOLD_CYCLES");
    if (holdEnv) s.holdCycles = std::max(1, std::atoi(holdEnv));

    // Fill both banks with distinct data
    s.fillFrame(0, 64);   // bank 0: Y=64 (dark gray)
    s.fillFrame(1, 200);  // bank 1: Y=200 (bright)
    s.resetCore();

    // Pre-doorbell settle (prime doorbell_primed)
    for (int i = 0; i < 3000; ++i)
        s.tick();

    // Phase 1: acquire bank 0 → has_frame=1
    s.ringDoorbell(0, 1);
    printf("  Phase 1: ring doorbell bank=0, seq=1\n");
    if (!s.waitForFrame(50000)) {
        printf("FAIL: first frame never asserted has_frame\n");
        return 1;
    }
    printf("  Phase 1: has_frame=1 achieved at cycle %llu\n", (unsigned long long)s.cycle);

    // Run a few frames to fully stabilize
    for (int i = 0; i < 10000; ++i)
        s.videoTick();
    printf("  Stable: has_frame=%d frames_done=%d underruns=%d\n",
           (int)s.top.has_frame, (int)s.top.frames_done, (int)s.top.underrun_count);

    // Phase 2: ring doorbell for bank 1 (triggers swap)
    // This is where the timing violation fires — disp_buf_d2 toggles
    s.ringDoorbell(1, 2);
    printf("  Phase 2: ring doorbell bank=1, seq=2 (swap trigger) inject=%d hold=%d\n",
           s.injectBankGlitch ? 1 : 0, s.holdCycles);

    // Run 100000 cycles and measure
    s.has_frame_cycles = 0;
    s.no_frame_cycles = 0;
    for (int i = 0; i < 100000; ++i) {
        s.videoTick();
    }

    int total = s.has_frame_cycles + s.no_frame_cycles;
    double frame_pct = total > 0 ? 100.0 * s.has_frame_cycles / total : 0.0;

    auto* r = s.top.rootp;
    printf("bank_glitch raw: "
           "inject=%d hold_cycles=%d glitch_count=%d "
           "has_frame_cycles=%d no_frame_cycles=%d total=%d "
           "has_frame_pct=%.1f%% underruns=%d frames_done=%d "
           "disp_buf_d2=%d swap_pending=%d pending_ready=%d ddr_reads=%d\n",
           s.injectBankGlitch ? 1 : 0, s.holdCycles, s.glitchCount,
           s.has_frame_cycles, s.no_frame_cycles, total,
           frame_pct, (int)s.top.underrun_count, (int)s.top.frames_done,
           (int)r->ddr_frame_store_want_y_glitch_tb__DOT__dut__DOT__disp_buf_d2,
           (int)s.top.swap_pending,
           (int)r->ddr_frame_store_want_y_glitch_tb__DOT__dut__DOT__pending_ready_c,
           s.ddrReadBursts);

    // Degeneracy guard (#18): if no DDR reads occurred, the test proved nothing.
    if (s.ddrReadBursts < 2) {
        printf("FAIL DEGENERACY: only %d DDR reads — test is trivially passing\n",
               s.ddrReadBursts);
        return 1;
    }

    bool stalled = (s.has_frame_cycles == 0);
    bool degraded = (frame_pct < 90.0);

    if (stalled)
        printf("VERDICT: STALLED — has_frame=0 after bank swap (frozen screen reproduced)\n");
    else if (degraded)
        printf("VERDICT: DEGRADED — has_frame=%.1f%% after swap\n", frame_pct);
    else
        printf("VERDICT: HEALTHY — has_frame=%.1f%% after swap (recovers from glitch)\n", frame_pct);

    return stalled ? 2 : (degraded ? 1 : 0);
}
