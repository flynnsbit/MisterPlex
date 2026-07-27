// want_y CDC glitch injection testbench driver.
//
// Two runs controlled by environment variable INJECT_GLITCH:
//   INJECT_GLITCH=0 (or unset): clean baseline
//   INJECT_GLITCH=1: corrupt want_y_gray_s2 every ~37 clk_ddr edges
//
// Measures: does the frame store converge to has_frame=1 within a
// reasonable window? If glitching want_y prevents convergence, that
// reproduces the silicon signature (PLXF present, has_frame=0 forever).

#include "Vddr_frame_store_want_y_glitch_tb.h"
#include "Vddr_frame_store_want_y_glitch_tb___024root.h"
#include "verilated.h"

#include <algorithm>
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
constexpr int kGlitchInterval = 37;

uint64_t pack8(uint8_t v) {
    uint64_t q = 0;
    for (int i = 0; i < 8; ++i)
        q |= static_cast<uint64_t>(v) << (i * 8);
    return q;
}

// Simulate the Gray-code conversion to produce the "correct" Gray value
// for a given binary input, then XOR upper bits to simulate a multi-bit
// binary transition glitch that the old sync path could produce.
uint8_t bin2gray(uint8_t b) { return b ^ (b >> 1); }
uint8_t gray2bin6(uint8_t g) {
    uint8_t b = 0;
    b |= (g & 0x20);
    for (int i = 4; i >= 0; --i)
        b |= ((b >> (i+1)) ^ ((g >> i) & 1)) << i;
    return b & 0x3f;
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
    bool injectGlitch = false;
    int glitchCtr = 0;
    int glitchCount = 0;
    int glitchInterval = kGlitchInterval;

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

    void injectWantYGlitch() {
        if (!injectGlitch) return;
        auto* r = top.rootp;
        uint8_t real_y = r->ddr_frame_store_want_y_glitch_tb__DOT__dut__DOT__want_y_sys;
        if (real_y < 3) return;  // don't glitch near reset
        if (++glitchCtr >= glitchInterval) {
            glitchCtr = 0;
            // Simulate worst-case multi-bit binary transition glitch.
            // A binary pointer crossing domains with a single sync stage
            // can resolve to any value when multiple bits transition.
            // Offset by half the frame height — maximum wrong eviction.
            uint8_t corrupted = (real_y + kH / 2) % kH;
            // Convert to Gray and inject into want_y_gray_s2
            r->ddr_frame_store_want_y_glitch_tb__DOT__dut__DOT__want_y_gray_s2 = bin2gray(corrupted);
            ++glitchCount;
        }
    }

    void tick() {
        // Falling edge
        top.clk = 0;
        top.clk_ddr = 0;
        top.eval();
        serviceDdrDrive();
        // Inject glitch BEFORE rising edge so the registered
        // desired_y_r captures the corrupted want_y_gray_s2 value.
        // The posedge will also overwrite want_y_gray_s2 via its
        // natural nonblocking assignment, so corruption is transient
        // (one capture window) — matching real metastability behavior.
        injectWantYGlitch();
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
};

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Sim s;

    const char* env = std::getenv("INJECT_GLITCH");
    s.injectGlitch = env && std::string(env) == "1";
    const char* rateEnv = std::getenv("GLITCH_RATE");
    if (rateEnv) s.glitchInterval = std::max(1, std::atoi(rateEnv));

    s.fillFrame(0, 64);
    s.resetCore();

    // Pre-doorbell settle: let poll_div cycle so doorbell_primed gets set
    // by an empty-data read (mirrors warm_reset bench pattern).
    for (int i = 0; i < 3000; ++i)
        s.tick();
    s.ringDoorbell(0, 1);

    constexpr int kSettleCycles = 60000;
    constexpr int kMeasureCycles = 40000;

    // Phase 1: let doorbell be found and initial fetch settle
    bool doorbell_found = false;
    for (int i = 0; i < kSettleCycles; ++i) {
        bool prev_dok = s.top.doorbell_ok;
        s.videoTick();
        if (!doorbell_found && s.top.doorbell_ok && !prev_dok) {
            printf("  doorbell_ok asserted at cycle %d\n", i);
            doorbell_found = true;
        }
    }

    // Phase 2: measure has_frame stability
    s.has_frame_cycles = 0;
    s.no_frame_cycles = 0;

    for (int i = 0; i < kMeasureCycles; ++i)
        s.videoTick();

    int total = s.has_frame_cycles + s.no_frame_cycles;
    double frame_pct = total > 0 ? 100.0 * s.has_frame_cycles / total : 0.0;

    printf("want_y_glitch raw: "
           "inject=%d glitch_count=%d "
           "has_frame_cycles=%d no_frame_cycles=%d total=%d "
           "has_frame_pct=%.1f%% underruns=%d frames_done=%d ddr_reads=%d\n",
           s.injectGlitch ? 1 : 0, s.glitchCount,
           s.has_frame_cycles, s.no_frame_cycles, total,
           frame_pct, (int)s.top.underrun_count, (int)s.top.frames_done,
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
        printf("VERDICT: STALLED — has_frame never asserted (frozen screen signature)\n");
    else if (degraded)
        printf("VERDICT: DEGRADED — has_frame=%.1f%% (intermittent display)\n", frame_pct);
    else
        printf("VERDICT: HEALTHY — has_frame=%.1f%%\n", frame_pct);

    return (stalled || degraded) ? 1 : 0;
}
