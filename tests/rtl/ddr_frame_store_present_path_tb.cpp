#include "Vddr_frame_store_present_path_tb.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 524288u;
constexpr int kCodedW = 624;
constexpr int kCodedH = 480;
constexpr int kPresentX = 11;
constexpr int kDisplayW = 618;
constexpr int kYQ = kCodedW / 8;
constexpr int kCQ = kCodedW / 16;
constexpr int kUQBase = (kCodedW * kCodedH) / 8;
constexpr int kVQBase = kUQBase + (kCodedW * kCodedH) / 32;

struct Rgb {
    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
};

uint8_t sat8(int v) {
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return static_cast<uint8_t>(v);
}

Rgb yuvToRgb(uint8_t y, uint8_t u, uint8_t v) {
    const int uu = static_cast<int>(u) - 128;
    const int vv = static_cast<int>(v) - 128;
    return {
        sat8((static_cast<int>(y) * 256 + 359 * vv) >> 8),
        sat8((static_cast<int>(y) * 256 - 88 * uu - 183 * vv) >> 8),
        sat8((static_cast<int>(y) * 256 + 454 * uu) >> 8),
    };
}

uint64_t pack8(uint8_t v) {
    uint64_t q = 0;
    for (int i = 0; i < 8; ++i)
        q |= static_cast<uint64_t>(v) << (i * 8);
    return q;
}

class Sim {
public:
    Vddr_frame_store_present_path_tb top{};
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

    uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

    void writeByte(int bank, int byteOffset, uint8_t v) {
        const uint32_t qoff = (bank * kBankStrideBytes + byteOffset) / 8;
        const int lane = byteOffset & 7;
        const uint64_t mask = 0xFFull << (lane * 8);
        mem[qoff] = (mem[qoff] & ~mask) | (static_cast<uint64_t>(v) << (lane * 8));
    }

    void fillConstant(int bank, uint8_t y, uint8_t u, uint8_t v) {
        const uint32_t base = (bank * kBankStrideBytes) / 8;
        for (int line = 0; line < kCodedH; ++line)
            for (int q = 0; q < kYQ; ++q)
                mem[base + line * kYQ + q] = pack8(y);
        for (int line = 0; line < kCodedH / 2; ++line) {
            for (int q = 0; q < kCQ; ++q) {
                mem[base + kUQBase + line * kCQ + q] = pack8(u);
                mem[base + kVQBase + line * kCQ + q] = pack8(v);
            }
        }
    }

    void fillUChromaPhasePattern(int bank) {
        fillConstant(bank, 128, 128, 128);
        const int yBytes = kCodedW * kCodedH;
        const int cBytes = (kCodedW / 2) * (kCodedH / 2);
        for (int cy = 0; cy < kCodedH / 2; ++cy) {
            for (int cx = 0; cx < kCodedW / 2; ++cx) {
                const uint8_t u = ((cx + cy) & 1) ? 255 : 0;
                writeByte(bank, yBytes + cy * (kCodedW / 2) + cx, u);
                writeByte(bank, yBytes + cBytes + cy * (kCodedW / 2) + cx, 128);
            }
        }
    }

    void fillVChromaPhasePattern(int bank) {
        fillConstant(bank, 128, 128, 128);
        const int yBytes = kCodedW * kCodedH;
        const int cBytes = (kCodedW / 2) * (kCodedH / 2);
        for (int cy = 0; cy < kCodedH / 2; ++cy) {
            for (int cx = 0; cx < kCodedW / 2; ++cx) {
                const uint8_t v = ((cx + cy) & 1) ? 255 : 0;
                writeByte(bank, yBytes + cy * (kCodedW / 2) + cx, 128);
                writeByte(bank, yBytes + cBytes + cy * (kCodedW / 2) + cx, v);
            }
        }
    }

    void kickBank(int bank) {
        top.bank_sel = bank;
        top.start_req = !top.start_req;
        for (int i = 0; i < 8; ++i)
            tick();
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

    bool waitForFrame(int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            if ((i % 997) == 0)
                pulseVsync();
            else
                tick();
            if (top.has_frame)
                return true;
        }
        return false;
    }

    bool waitForFramesDoneAbove(int start, int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            if ((i % 997) == 0)
                pulseVsync();
            else
                tick();
            if (top.frames_done > start)
                return true;
        }
        return false;
    }

    Rgb sample(int x, int y) {
        top.rd_x = x;
        top.rd_y = y;
        top.rd_active = 1;
        for (int i = 0; i < 3000; ++i)
            tick();
        return {static_cast<uint8_t>(top.rd_r), static_cast<uint8_t>(top.rd_g),
                static_cast<uint8_t>(top.rd_b)};
    }

};

void requireNear(const std::string& label, Rgb got, Rgb want, int tolerance = 1) {
    const auto ok = [&](uint8_t a, uint8_t b) {
        const int d = static_cast<int>(a) - static_cast<int>(b);
        return d >= -tolerance && d <= tolerance;
    };
    if (!ok(got.r, want.r) || !ok(got.g, want.g) || !ok(got.b, want.b)) {
        std::cerr << "FAIL ddr_frame_store present-path " << label << ": got RGB=["
                  << int(got.r) << "," << int(got.g) << "," << int(got.b)
                  << "] want≈[" << int(want.r) << "," << int(want.g) << ","
                  << int(want.b) << "]\n";
        std::exit(1);
    }
}

void run() {
    int totalFrames = 0;
    int totalUnderruns = 0;
    uint64_t totalCycles = 0;

    {
        Sim sim;
        sim.fillConstant(0, 16, 128, 128);
        sim.resetCore();
        for (int i = 0; i < 3000; ++i)
            sim.tick();
        sim.kickBank(0);
        if (!sim.waitForFrame(100000))
            throw std::runtime_error("neutral bank did not present");
        requireNear("left pillar black", sim.sample(0, 0), {0, 0, 0}, 0);
        requireNear("pre-active pillar black", sim.sample(kPresentX - 1, 0), {0, 0, 0}, 0);
        requireNear("first active neutral", sim.sample(kPresentX, 0), yuvToRgb(16, 128, 128));
        requireNear("interior active neutral", sim.sample(170, 119), yuvToRgb(16, 128, 128));
        requireNear("last active neutral", sim.sample(kPresentX + kDisplayW - 1, 479),
                    yuvToRgb(16, 128, 128));
        requireNear("right pillar black", sim.sample(kPresentX + kDisplayW, 0), {0, 0, 0}, 0);
        totalFrames += sim.top.frames_done;
        totalUnderruns += sim.top.underrun_count;
        totalCycles += sim.cycle;
    }

    {
        Sim sim;
        sim.fillUChromaPhasePattern(0);
        sim.resetCore();
        for (int i = 0; i < 3000; ++i)
            sim.tick();
        sim.kickBank(0);
        if (!sim.waitForFrame(100000))
            throw std::runtime_error("U chroma phase bank did not present");
        const Rgb u0 = yuvToRgb(128, 0, 128);
        const Rgb u255 = yuvToRgb(128, 255, 128);
        requireNear("U chroma sample x0", sim.sample(kPresentX, 0), u0);
        requireNear("U chroma horizontal replicate x1", sim.sample(kPresentX + 1, 0), u0);
        requireNear("U chroma horizontal advance x2", sim.sample(kPresentX + 2, 0), u255);
        requireNear("U chroma vertical replicate y1", sim.sample(kPresentX, 1), u0);
        requireNear("U chroma vertical advance y2", sim.sample(kPresentX, 2), u255);
        requireNear("U chroma interior phase", sim.sample(kPresentX + 39, 37),
                    (((39 / 2) + (37 / 2)) & 1) ? u255 : u0);
        totalFrames += sim.top.frames_done;
        totalUnderruns += sim.top.underrun_count;
        totalCycles += sim.cycle;
    }

    {
        Sim sim;
        sim.fillVChromaPhasePattern(0);
        sim.resetCore();
        for (int i = 0; i < 3000; ++i)
            sim.tick();
        sim.kickBank(0);
        if (!sim.waitForFrame(100000))
            throw std::runtime_error("V chroma phase bank did not present");
        const Rgb v0 = yuvToRgb(128, 128, 0);
        const Rgb v255 = yuvToRgb(128, 128, 255);
        requireNear("V chroma sample x0", sim.sample(kPresentX, 0), v0);
        requireNear("V chroma horizontal replicate x1", sim.sample(kPresentX + 1, 0), v0);
        requireNear("V chroma horizontal advance x2", sim.sample(kPresentX + 2, 0), v255);
        requireNear("V chroma vertical replicate y1", sim.sample(kPresentX, 1), v0);
        requireNear("V chroma vertical advance y2", sim.sample(kPresentX, 2), v255);
        requireNear("V chroma interior phase", sim.sample(kPresentX + 39, 37),
                    (((39 / 2) + (37 / 2)) & 1) ? v255 : v0);
        totalFrames += sim.top.frames_done;
        totalUnderruns += sim.top.underrun_count;
        totalCycles += sim.cycle;
    }

    const Rgb u0 = yuvToRgb(128, 0, 128);
    const Rgb u255 = yuvToRgb(128, 255, 128);
    const Rgb v0 = yuvToRgb(128, 128, 0);
    const Rgb v255 = yuvToRgb(128, 128, 255);
    std::cout << "ddr_frame_store present-path raw: neutral RGB="
              << int(yuvToRgb(16, 128, 128).r) << ","
              << int(yuvToRgb(16, 128, 128).g) << ","
              << int(yuvToRgb(16, 128, 128).b)
              << " u0 RGB=" << int(u0.r) << "," << int(u0.g) << "," << int(u0.b)
              << " u255 RGB=" << int(u255.r) << "," << int(u255.g) << ","
              << int(u255.b)
              << " v0 RGB=" << int(v0.r) << "," << int(v0.g) << "," << int(v0.b)
              << " v255 RGB=" << int(v255.r) << "," << int(v255.g) << ","
              << int(v255.b) << " frames=" << totalFrames
              << " underruns=" << totalUnderruns << " cycles=" << totalCycles
              << "\n";
    std::cout << "OK ddr_frame_store present-path: product geometry, pillars, "
                 "YUV conversion, and U/V 4:2:0 chroma phase are correct\n";
}
} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        run();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL ddr_frame_store present-path: " << e.what() << "\n";
        return 1;
    }
}
