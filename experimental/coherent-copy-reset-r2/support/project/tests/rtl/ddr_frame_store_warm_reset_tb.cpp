#include "Vddr_frame_store_warm_reset_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdlib>
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
constexpr uint32_t kFrameMailboxPhys = 0x3001F118u;
constexpr uint32_t kInputMailboxPhys = 0x3001F108u;
constexpr uint32_t kStatusMailboxPhys = 0x3001F100u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr uint32_t kFrameMailboxMagic = 0x504C5846u;
constexpr uint32_t kInputMailboxMagic = 0x504C5849u;
constexpr uint32_t kStatusMailboxMagic = 0x504C5853u;
constexpr int kW = 80;
constexpr int kH = 48;
constexpr int kYQ = kW / 8;
constexpr int kCQ = kW / 16;
constexpr int kUQBase = (kW * kH) / 8;
constexpr int kVQBase = kUQBase + (kW * kH) / 32;
constexpr uint32_t kSeqMask = 0x1fffffffu;
constexpr int kDoorbellFormatRgb565 = 0;
constexpr int kDoorbellFormatYuv420p = 1;
constexpr uint8_t kDebugFormatError = 0xE1;

uint32_t doorbellHi(uint32_t seq, int bank, int format = kDoorbellFormatYuv420p) {
    return (static_cast<uint32_t>(bank & 1) << 31) |
           (static_cast<uint32_t>(format & 0x3) << 29) | (seq & 0x1fffffffu);
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

struct Rgb {
    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
};

class Sim {
public:
    Vddr_frame_store_warm_reset_tb top{};
    std::vector<uint64_t> mem;
    std::vector<uint64_t> inputMailboxes;
    std::vector<uint64_t> statusMailboxes;
    uint64_t cycle = 0;
    int busy = 0;
    int rdDelay = -1;
    uint32_t rdAddr = 0;
    int rdLeft = 0;
    int rdIndex = 0;
    int scanX = 0;
    int scanY = 0;
    bool schedHighBeforeEdge = false;
    bool schedulerArmed = false;
    bool sawSchedValid = false;
    bool sawScheduledLineRead = false;
    bool hangLineReadResponses = false;
    bool sawDroppedLineRead = false;
    bool forceDdrBusy = false;
    bool pauseDdrClock = false;
    bool startToggle = false;
    int ddrPeriod = 0;
    int ddrPhase = 0;
    int pixelPeriod = 10;
    uint64_t clockTime = 0;
    uint64_t ddrEdges = 0;
    bool watchActiveCache = false;
    bool replaceOnRetire = false;
    bool replacementObserved = false;
    uint64_t replacementPostedAt = 0;
    std::string protocolLabel;

    explicit Sim(int period = 0, int phase = 0, int pixel_period = 10)
        : mem((2 * kBankStrideBytes) / 8, 0), ddrPeriod(period), ddrPhase(phase),
          pixelPeriod(pixel_period) {
        top.clk = 0;
        top.clk_ddr = 0;
        top.reset = 0;
        top.rd_x = 0;
        top.rd_y = 0;
        top.rd_active = 0;
        top.start_req = 0;
        top.bank_sel = 0;
        top.vsync_pulse = 0;
        top.input_cmd_valid = 0;
        top.input_cmd = 0;
        top.status_osd = 0;
        top.test_override_disp_sync = 0;
        top.test_disp_sync = 0;
        top.test_override_pending_sync = 0;
        top.test_pending_sync = 0;
        top.test_override_start_sync = 0;
        top.test_start_sync = 0;
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

    void fillFrameChromaRows(int bank, uint8_t y, const std::vector<uint8_t>& uRows, uint8_t v = 128) {
        const uint32_t base = (bank * kBankStrideBytes) / 8;
        for (int line = 0; line < kH; ++line)
            for (int q = 0; q < kYQ; ++q)
                mem[base + line * kYQ + q] = pack8(y);
        for (int line = 0; line < kH / 2; ++line) {
            const uint8_t u = uRows.empty() ? 128 : uRows[std::min<int>(line, static_cast<int>(uRows.size()) - 1)];
            for (int q = 0; q < kCQ; ++q) {
                mem[base + kUQBase + line * kCQ + q] = pack8(u);
                mem[base + kVQBase + line * kCQ + q] = pack8(v);
            }
        }
    }

    void ringDoorbell(int bank, uint32_t seq, int format = kDoorbellFormatYuv420p) {
        const uint32_t off = offQ(kDoorbellPhys);
        mem[off] = static_cast<uint64_t>(doorbellHi(seq, bank, format)) << 32 | kMagic;
    }

    uint64_t frameMailbox() const {
        return mem[offQ(kFrameMailboxPhys)];
    }

    bool waitForFrameDebug(uint8_t debug, int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            const uint64_t mbox = frameMailbox();
            if (static_cast<uint32_t>(mbox) == kFrameMailboxMagic &&
                static_cast<uint8_t>((mbox >> 40) & 0xffu) == debug)
                return true;
            tick();
        }
        return false;
    }

    bool waitForFrameMailboxMagic(int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            if (static_cast<uint32_t>(frameMailbox()) == kFrameMailboxMagic)
                return true;
            tick();
        }
        return false;
    }

    void serviceDdrStart() {
        if (top.DDRAM_RD && !forceDdrBusy && busy == 0 && rdDelay < 0 && rdLeft == 0) {
            if (schedulerArmed) {
                sawScheduledLineRead = true;
                schedulerArmed = false;
            }
            if (hangLineReadResponses && top.DDRAM_ADDR != (kDoorbellPhys >> 3)) {
                sawDroppedLineRead = true;
                return;
            }
            rdAddr = top.DDRAM_ADDR;
            rdLeft = top.DDRAM_BURSTCNT;
            rdIndex = 0;
            rdDelay = 2;
            busy = rdLeft + rdDelay + 1;
        }
        if (top.DDRAM_WE && !forceDdrBusy && busy == 0) {
            const uint32_t off = addrOffQ(top.DDRAM_ADDR);
            if (off < mem.size())
                mem[off] = top.DDRAM_DIN;
            if (top.DDRAM_ADDR == (kInputMailboxPhys >> 3))
                inputMailboxes.push_back(top.DDRAM_DIN);
            if (top.DDRAM_ADDR == (kStatusMailboxPhys >> 3))
                statusMailboxes.push_back(top.DDRAM_DIN);
            busy = 2;
        }
    }

    void serviceDdrDrive() {
        top.DDRAM_DOUT_READY = 0;
        if (busy > 0)
            --busy;
        top.DDRAM_BUSY = forceDdrBusy || (busy > 0);
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

    void clockEdge(bool pixelEdge, bool ddrEdge) {
        top.clk = 0;
        top.clk_ddr = 0;
        top.eval();
        bool replacementEdge = false;
        if (ddrEdge) {
            schedHighBeforeEdge = top.debug_sched_valid;
            if (schedHighBeforeEdge) {
                sawSchedValid = true;
                schedulerArmed = true;
            }
            serviceDdrDrive();
            if (replaceOnRetire && top.debug_queue_retire_opportunity) {
                if (ddrEdges - replacementPostedAt < 2 || top.debug_bank_sel_d2 != 1)
                    throw std::runtime_error("replacement fixture lacks held source setup");
                top.test_start_sync = top.start_req;
                top.eval();
                if (top.debug_start_d2 == top.debug_start_seen)
                    throw std::runtime_error("replacement fixture did not deliver a new accepted start");
                replacementEdge = true;
                replaceOnRetire = false;
            }
        }
        const uint8_t yValidBefore = top.debug_y_valid;
        const uint8_t cValidBefore = top.debug_c_valid;
        top.clk = pixelEdge;
        top.clk_ddr = ddrEdge;
        top.eval();
        if (ddrEdge) {
            ++ddrEdges;
            serviceDdrStart();
            if (watchActiveCache && !top.reset && top.has_frame) {
                const uint8_t activeMask = top.debug_disp_buf ? 0xf0 : 0x0f;
                const uint8_t cleared = (yValidBefore & ~top.debug_y_valid) |
                                        (cValidBefore & ~top.debug_c_valid);
                if ((cleared & activeMask) != 0)
                    throw std::runtime_error(protocolLabel + ": ownership CDC cleared an active cache");
            }
            if (replacementEdge) {
                replacementObserved = true;
                if (!top.debug_queued_refresh_valid || top.debug_queued_refresh_bank != 1)
                    throw std::runtime_error(protocolLabel + ": accepted replacement lost at queue retirement");
                std::cout << "ddr_frame_store protocol: replacement collision"
                          << " source_lead_ddr_edges=" << ddrEdges - replacementPostedAt
                          << " queued_bank=" << int(top.debug_queued_refresh_bank) << "\n";
            }
        }
        top.clk = 0;
        top.clk_ddr = 0;
        top.eval();
        if (pixelEdge) {
            ++cycle;
            top.vsync_pulse = 0;
        }
    }

    void tick() {
        if (ddrPeriod == 0) {
            clockEdge(true, !pauseDdrClock);
            return;
        }
        bool pixelEdge;
        do {
            ++clockTime;
            pixelEdge = clockTime % pixelPeriod == 0;
            const bool ddrEdge = !pauseDdrClock && (clockTime + ddrPhase) % ddrPeriod == 0;
            if (pixelEdge || ddrEdge)
                clockEdge(pixelEdge, ddrEdge);
        } while (!pixelEdge);
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

    void pulseVsync() {
        top.vsync_pulse = 1;
        tick();
    }

    void triggerStart(int bank) {
        top.bank_sel = bank & 1;
        startToggle = !startToggle;
        top.start_req = startToggle;
        for (int i = 0; i < 4; ++i)
            tick();
    }

    bool waitCyclesNoFrame(int n) {
        for (int i = 0; i < n; ++i) {
            videoTick();
            if (top.has_frame)
                return false;
        }
        return true;
    }

    bool waitForFrame(int maxCycles) {
        const int startFrames = top.frames_done;
        return waitForFrameCount(startFrames + 1, maxCycles);
    }

    bool waitForFrameCount(int minFrames, int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            videoTick();
            if (top.frames_done >= minFrames)
                return true;
        }
        return false;
    }

    bool waitForFrameCountStatic(int minFrames, int maxCycles) {
        top.rd_active = 0;
        top.rd_x = 0;
        top.rd_y = 0;
        for (int i = 0; i < maxCycles; ++i) {
            if ((i % 97) == 0)
                pulseVsync();
            else
                tick();
            if (top.frames_done >= minFrames)
                return true;
        }
        return false;
    }

    bool waitForPendingReady(int maxCycles) {
        top.rd_active = 0;
        top.rd_x = 0;
        top.rd_y = 0;
        for (int i = 0; i < maxCycles; ++i) {
            if (top.swap_pending && top.debug_pending_ready &&
                top.debug_pending_ready_id == top.debug_pending_req_id)
                return true;
            tick();
        }
        return false;
    }

    uint8_t sample(int x, int y) {
        const int saveX = scanX;
        const int saveY = scanY;
        top.rd_x = x;
        top.rd_y = y;
        top.rd_active = 1;
        for (int i = 0; i < 18; ++i)
            tick();
        top.rd_active = 0;
        tick();
        scanX = saveX;
        scanY = saveY;
        return top.rd_r;
    }

    Rgb sampleRgb(int x, int y) {
        const int saveX = scanX;
        const int saveY = scanY;
        top.rd_x = x;
        top.rd_y = y;
        top.rd_active = 1;
        for (int i = 0; i < 18; ++i)
            tick();
        top.rd_active = 0;
        tick();
        scanX = saveX;
        scanY = saveY;
        return {top.rd_r, top.rd_g, top.rd_b};
    }

    bool schedulerProven() const { return sawSchedValid && sawScheduledLineRead; }
};

uint8_t stableSample(Sim& sim) {
    for (int i = 0; i < 1000; ++i)
        sim.tick();
    return sim.sample(0, 0);
}

Rgb stableSampleRgb(Sim& sim) {
    for (int i = 0; i < 1000; ++i)
        sim.tick();
    return sim.sampleRgb(0, 0);
}

Rgb stableSampleRgbAt(Sim& sim, int x, int y) {
    sim.top.rd_x = x;
    sim.top.rd_y = y;
    sim.top.rd_active = 1;
    for (int i = 0; i < 1600; ++i)
        sim.tick();
    return sim.sampleRgb(x, y);
}

void expectFreshSample(const std::string& label, Sim& sim, uint8_t want) {
    const uint8_t got = stableSample(sim);
    if (got + 1 < want || got > want + 1) {
        std::cerr << "FAIL ddr_frame_store warm-reset: " << label << " got r=" << int(got)
                  << " want≈" << int(want) << " frames=" << sim.top.frames_done
                  << " underruns=" << sim.top.underrun_count
                  << " has_frame=" << int(sim.top.has_frame)
                  << " swap_pending=" << int(sim.top.swap_pending)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }
}

bool runFreshNoStale() {
    Sim sim;
    sim.fillFrame(1, 208);
    sim.resetCore();
    for (int i = 0; i < 3000; ++i)
        sim.tick();
    sim.ringDoorbell(1, 1);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error("first fresh doorbell without stale magic did not produce a frame");
    expectFreshSample("first fresh no-stale", sim, 208);
    return sim.schedulerProven();
}

bool runInitialFrameMailboxPublish() {
    Sim sim;
    sim.resetCore();
    if (!sim.waitForFrameMailboxMagic(20000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: PLXF frame mailbox did not publish"
                  << " after reset mailbox=0x" << std::hex << sim.frameMailbox()
                  << std::dec << " cycle=" << sim.cycle << "\n";
        std::exit(1);
    }
    if (sim.cycle >= 224) {
        std::cerr << "FAIL ddr_frame_store warm-reset: initial PLXF publish waited for legacy poll slot"
                  << " cycles=" << sim.cycle << "\n";
        std::exit(1);
    }
    const uint64_t mbox = sim.frameMailbox();
    std::cout << "ddr_frame_store warm-reset raw: initial_plxf_publish"
              << " frame_mailbox_magic=0x" << std::hex << static_cast<uint32_t>(mbox)
              << " frame_debug=0x" << int((mbox >> 40) & 0xffu)
              << std::dec << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

void runInputMailboxSequence() {
    Sim sim;
    sim.resetCore();
    for (unsigned batch = 0; batch < 100; ++batch) {
        sim.forceDdrBusy = true;
        for (unsigned item = 0; item < 3; ++item) {
            sim.top.input_cmd = (batch * 3 + item) % 255 + 1;
            sim.top.input_cmd_valid = 1;
            sim.tick();
        }
        sim.top.input_cmd_valid = 0;
        for (int i = 0; i < 25; ++i) sim.tick();
        sim.forceDdrBusy = false;
        const size_t expected = (batch + 1) * 3;
        for (int i = 0; i < 20000 && sim.inputMailboxes.size() < expected; ++i)
            sim.tick();
        if (sim.inputMailboxes.size() != expected)
            throw std::runtime_error("input mailbox lost or repeated a queued command: expected=" +
                std::to_string(expected) + " received=" + std::to_string(sim.inputMailboxes.size()) +
                " state=" + std::to_string(sim.top.debug_state));
    }
    for (size_t i = 0; i < sim.inputMailboxes.size(); ++i) {
        const uint64_t word = sim.inputMailboxes[i];
        if (static_cast<uint32_t>(word) != kInputMailboxMagic ||
            ((word >> 32) & 0xffu) != i % 255 + 1 ||
            ((word >> 40) & 0xffu) != ((i + 1) & 0xffu) ||
            (word >> 48) != i + 1)
            throw std::runtime_error("input mailbox command/order/sequence mismatch");
    }
    sim.forceDdrBusy = true;
    sim.top.input_cmd = 222;
    sim.top.input_cmd_valid = 1;
    sim.tick();
    sim.top.input_cmd_valid = 0;
    sim.resetCore();
    sim.inputMailboxes.clear();
    sim.forceDdrBusy = false;
    for (int i = 0; i < 1000; ++i) sim.tick();
    if (!sim.inputMailboxes.empty())
        throw std::runtime_error("input mailbox replayed a command across reset");
    sim.top.input_cmd = 17;
    sim.top.input_cmd_valid = 1;
    sim.tick();
    sim.top.input_cmd_valid = 0;
    for (int i = 0; i < 20000 && sim.inputMailboxes.empty(); ++i) sim.tick();
    const uint64_t first = (uint64_t{1} << 48) | (uint64_t{1} << 40) |
                           (uint64_t{17} << 32) | kInputMailboxMagic;
    if (sim.inputMailboxes.size() != 1 || sim.inputMailboxes[0] != first)
        throw std::runtime_error("input mailbox sequence did not restart at one");
    std::cout << "ddr_frame_store warm-reset raw: input_mailbox_sequence commands=300 wrap=1 reset=1\n";
}

void runUnderrunMailboxSnapshot() {
    Sim sim;
    sim.fillFrame(1, 208);
    sim.resetCore();
    for (int i = 0; i < 3000; ++i) sim.tick();
    sim.ringDoorbell(1, 1);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error("underrun snapshot setup did not produce a frame");
    sim.forceDdrBusy = true;
    sim.top.rd_x = 0;
    sim.top.rd_y = kH - 1;
    uint16_t previousSafe = 0;
    for (unsigned target : {256u, 32768u, 65535u}) {
        sim.top.rd_active = 1;
        for (int i = 0; i < 70000 && sim.top.underrun_count < target; ++i) {
            sim.tick();
            const uint16_t safe = sim.top.debug_underrun_safe;
            if (safe < previousSafe || safe > sim.top.underrun_count)
                throw std::runtime_error("underrun CDC count was torn or nonmonotonic");
            previousSafe = safe;
        }
        if (sim.top.underrun_count < target)
            throw std::runtime_error("underrun snapshot did not cross the requested carry");
        sim.top.rd_active = 0;
        for (int i = 0; i < 8; ++i) sim.tick();
        if (sim.top.debug_underrun_safe != sim.top.underrun_count)
            throw std::runtime_error("underrun CDC count did not converge after misses stopped");
        previousSafe = sim.top.debug_underrun_safe;
    }
    sim.top.rd_active = 1;
    for (int i = 0; i < 16; ++i) sim.tick();
    if (sim.top.underrun_count != 65535 || sim.top.debug_underrun_safe != 65535)
        throw std::runtime_error("underrun count did not saturate");
    sim.top.rd_active = 0;
    sim.forceDdrBusy = false;
    for (int i = 0; i < 100000 && (sim.frameMailbox() >> 48) != 65535; ++i) sim.tick();
    if (static_cast<uint32_t>(sim.frameMailbox()) != kFrameMailboxMagic ||
        (sim.frameMailbox() >> 48) != 65535)
        throw std::runtime_error("PLXF did not publish the settled underrun count");
    sim.resetCore();
    if (sim.top.underrun_count || sim.top.debug_underrun_safe)
        throw std::runtime_error("underrun CDC count survived reset");
    std::cout << "ddr_frame_store warm-reset raw: underrun_cdc carries=256,32768 saturation=65535 reset=0\n";
}

bool runInitialFrameMailboxAbsentWhenDdrBusy() {
    Sim sim;
    sim.forceDdrBusy = true;
    sim.resetCore();
    for (int i = 0; i < 20000; ++i)
        sim.tick();
    const uint64_t mbox = sim.frameMailbox();
    if (static_cast<uint32_t>(mbox) != 0 || sim.top.has_frame) {
        std::cerr << "FAIL ddr_frame_store warm-reset: forced DDR busy should leave PLXF absent"
                  << " mailbox=0x" << std::hex << mbox
                  << " has_frame=" << std::dec << int(sim.top.has_frame) << "\n";
        std::exit(1);
    }
    std::cout << "ddr_frame_store warm-reset raw: initial_plxf_absent_when_ddr_busy"
              << " frame_mailbox_magic=0x" << std::hex << static_cast<uint32_t>(mbox)
              << " full_mailbox=0x" << mbox
              << std::dec << " has_frame=" << int(sim.top.has_frame)
              << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runFrameMailboxStallsWithHungLineRead() {
    Sim sim;
    sim.fillFrame(0, 218);
    sim.resetCore();
    if (!sim.waitForFrameMailboxMagic(20000))
        throw std::runtime_error("line-read-hang setup: initial PLXF mailbox did not publish");
    sim.hangLineReadResponses = true;
    sim.ringDoorbell(0, 0x69);
    for (int i = 0; i < 100000 && !sim.sawDroppedLineRead; ++i)
        sim.videoTick();
    if (!sim.sawDroppedLineRead) {
        std::cerr << "FAIL ddr_frame_store warm-reset: line-read-hang did not reach a frame line read"
                  << " has_frame=" << int(sim.top.has_frame)
                  << " debug=0x" << std::hex << int(sim.top.debug_state)
                  << " mailbox=0x" << sim.frameMailbox() << std::dec << "\n";
        std::exit(1);
    }
    const uint64_t staleMbox = sim.frameMailbox();
    for (int i = 0; i < 20000; ++i)
        sim.videoTick();
    const uint64_t laterMbox = sim.frameMailbox();
    if (sim.top.has_frame || laterMbox != staleMbox) {
        std::cerr << "FAIL ddr_frame_store warm-reset: hung line read did not leave PLXF stale"
                  << " has_frame=" << int(sim.top.has_frame)
                  << " before=0x" << std::hex << staleMbox
                  << " after=0x" << laterMbox
                  << " live_debug=0x" << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }
    std::cout << "ddr_frame_store warm-reset raw: line_read_hang_plxf_stale"
              << " plxf=0x" << std::hex << laterMbox
              << " live_debug=0x" << int(sim.top.debug_state)
              << std::dec << " has_frame=" << int(sim.top.has_frame)
              << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runChromaPlaneReadMapping() {
    Sim sim;
    sim.fillFrame(0, 128, 255, 0);
    sim.resetCore();
    for (int i = 0; i < 3000; ++i)
        sim.tick();
    sim.ringDoorbell(0, 11);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error("chroma U/V read mapping: frame did not present");

    const Rgb got = stableSampleRgb(sim);
    if (!(got.r <= 8 && got.b >= 248 && got.g >= 160 && got.g <= 190)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: U/V read mapping got rgb="
                  << int(got.r) << "/" << int(got.g) << "/" << int(got.b)
                  << " want blue-dominant from Y=128 U=255 V=0"
                  << " u_base_qwords=" << kUQBase << " v_base_qwords=" << kVQBase
                  << " y_stride_qwords=" << kYQ << " c_stride_qwords=" << kCQ
                  << " frames=" << sim.top.frames_done
                  << " underruns=" << sim.top.underrun_count << "\n";
        std::exit(1);
    }

    std::cout << "ddr_frame_store chroma raw: U_base_qwords=" << kUQBase
              << " V_base_qwords=" << kVQBase
              << " U_base_bytes=" << (kUQBase * 8)
              << " V_base_bytes=" << (kVQBase * 8)
              << " Y_stride_qwords=" << kYQ
              << " C_stride_qwords=" << kCQ
              << " Y_stride_bytes=" << (kYQ * 8)
              << " C_stride_bytes=" << (kCQ * 8)
              << " sample_rgb=" << int(got.r) << "/" << int(got.g) << "/" << int(got.b)
              << " frames=" << sim.top.frames_done
              << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runChromaVerticalStrideMapping() {
    Sim sim;
    sim.fillFrameChromaRows(0, 128, {128, 180, 70});
    sim.resetCore();
    for (int i = 0; i < 3000; ++i)
        sim.tick();
    sim.ringDoorbell(0, 12);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error("chroma vertical/stride mapping: frame did not present");

    const Rgb y0 = stableSampleRgbAt(sim, 0, 0);
    const Rgb y1 = stableSampleRgbAt(sim, 0, 1);
    const Rgb y2 = stableSampleRgbAt(sim, 0, 2);
    if (!(std::abs(int(y0.b) - 128) <= 8 && std::abs(int(y1.b) - 128) <= 8 && y2.b >= 205)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: chroma vertical subsampling/stride"
                  << " y0_rgb=" << int(y0.r) << "/" << int(y0.g) << "/" << int(y0.b)
                  << " y1_rgb=" << int(y1.r) << "/" << int(y1.g) << "/" << int(y1.b)
                  << " y2_rgb=" << int(y2.r) << "/" << int(y2.g) << "/" << int(y2.b)
                  << " want y0/y1 from chroma row0 and y2 from chroma row1"
                  << " bench_y_stride_bytes=" << (kYQ * 8)
                  << " bench_c_stride_bytes=" << (kCQ * 8)
                  << " product_c_stride_bytes=312"
                  << " frames=" << sim.top.frames_done
                  << " underruns=" << sim.top.underrun_count << "\n";
        std::exit(1);
    }

    std::cout << "ddr_frame_store chroma vertical/stride raw: y0_rgb="
              << int(y0.r) << "/" << int(y0.g) << "/" << int(y0.b)
              << " y1_rgb=" << int(y1.r) << "/" << int(y1.g) << "/" << int(y1.b)
              << " y2_rgb=" << int(y2.r) << "/" << int(y2.g) << "/" << int(y2.b)
              << " bench_Y_stride_bytes=" << (kYQ * 8)
              << " bench_C_stride_bytes=" << (kCQ * 8)
              << " product_Y_stride_bytes=624 product_C_stride_bytes=312"
              << " frames=" << sim.top.frames_done << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runWarmResetChanged(uint32_t staleSeq, uint32_t freshSeq, int staleBank, int freshBank,
                         uint8_t freshY, const std::string& label) {
    Sim sim;
    sim.fillFrame(0, 48);
    sim.fillFrame(1, freshY);
    sim.ringDoorbell(staleBank, staleSeq);
    sim.resetCore();

    if (!sim.waitCyclesNoFrame(25000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: accepted stale doorbell before fresh frame"
                  << " label=" << label << " cycle=" << sim.cycle
                  << " frames=" << sim.top.frames_done << "\n";
        std::exit(1);
    }

    sim.ringDoorbell(freshBank, freshSeq);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error(label + ": fresh doorbell did not produce a frame");
    expectFreshSample(label, sim, freshY);

    std::cout << "ddr_frame_store warm-reset raw: " << label << " stale_seq=" << staleSeq
              << " fresh_seq=" << freshSeq << " stale_bank=" << staleBank
              << " fresh_bank=" << freshBank << " no_frame_cycles=25000 frames="
              << sim.top.frames_done << " sample_x=0 sample_y=0 sample_r=" << int(freshY)
              << " underruns=" << sim.top.underrun_count << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runRejectNonYuvDoorbell() {
    {
        Sim sim;
        sim.fillFrame(0, 61);
        sim.fillFrame(1, 213);
        sim.resetCore();
        for (int i = 0; i < 3000; ++i)
            sim.tick();
        sim.ringDoorbell(0, 2, kDoorbellFormatRgb565);
        if (!sim.waitCyclesNoFrame(25000)) {
            std::cerr << "FAIL ddr_frame_store warm-reset: accepted non-YUV doorbell"
                      << " cycle=" << sim.cycle << " frames=" << sim.top.frames_done << "\n";
            std::exit(1);
        }
        if (sim.top.debug_state != kDebugFormatError) {
            std::cerr << "FAIL ddr_frame_store warm-reset: non-YUV doorbell debug=0x"
                      << std::hex << int(sim.top.debug_state) << " want=0x"
                      << int(kDebugFormatError) << std::dec << "\n";
            std::exit(1);
        }
        if (!sim.waitForFrameDebug(kDebugFormatError, 20000)) {
            std::cerr << "FAIL ddr_frame_store warm-reset: non-YUV doorbell did not publish"
                      << " PLXF frame_debug=0x" << std::hex << int(kDebugFormatError)
                      << " mailbox=0x" << sim.frameMailbox() << std::dec << "\n";
            std::exit(1);
        }
        sim.ringDoorbell(1, 2, kDoorbellFormatYuv420p);
        if (!sim.waitForFrame(50000))
            throw std::runtime_error("valid YUV doorbell did not recover after live non-YUV reject");
        expectFreshSample("live non-YUV reject then YUV accept", sim, 213);
    }

    Sim sim;
    sim.fillFrame(0, 60);
    sim.fillFrame(1, 213);
    sim.ringDoorbell(0, 4, kDoorbellFormatRgb565);
    sim.resetCore();
    if (!sim.waitCyclesNoFrame(25000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: accepted non-YUV doorbell"
                  << " cycle=" << sim.cycle << " frames=" << sim.top.frames_done << "\n";
        std::exit(1);
    }
    if (sim.top.debug_state != kDebugFormatError) {
        std::cerr << "FAIL ddr_frame_store warm-reset: non-YUV doorbell debug=0x"
                  << std::hex << int(sim.top.debug_state) << " want=0x"
                  << int(kDebugFormatError) << std::dec << "\n";
        std::exit(1);
    }
    if (!sim.waitForFrameDebug(kDebugFormatError, 20000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: non-YUV doorbell did not publish"
                  << " PLXF frame_debug=0x" << std::hex << int(kDebugFormatError)
                  << " mailbox=0x" << sim.frameMailbox() << std::dec << "\n";
        std::exit(1);
    }

    sim.ringDoorbell(1, 4, kDoorbellFormatYuv420p);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error("valid YUV doorbell did not recover after non-YUV reject");
    expectFreshSample("non-YUV reject then YUV accept", sim, 213);

    std::cout << "ddr_frame_store warm-reset raw: non_yuv_reject rejected_format=0 frame_debug=0x"
              << std::hex << int(kDebugFormatError) << std::dec
              << " frame_mailbox_magic=0x" << std::hex << kFrameMailboxMagic << std::dec
              << " fresh_format=1 seq=4 stale_bank=0 fresh_bank=1 no_frame_cycles=25000"
              << " frames=" << sim.top.frames_done << " sample_r=213 underruns="
              << sim.top.underrun_count << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runRunningArmRestartLower() {
    Sim sim;
    sim.fillFrame(0, 96);
    sim.resetCore();
    sim.ringDoorbell(0, 9);
    if (!sim.waitForFrame(800000))
        throw std::runtime_error("running-restart: initial frame did not present");
    expectFreshSample("running-restart initial", sim, 96);

    const int prevFrames = sim.top.frames_done;
    sim.fillFrame(1, 214);
    sim.ringDoorbell(1, 1);
    if (!sim.waitForFrameCountStatic(prevFrames + 1, 800000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: running-restart no second frame"
                  << " prev_frames=" << prevFrames << " frames=" << sim.top.frames_done
                  << " has_frame=" << int(sim.top.has_frame)
                  << " swap_pending=" << int(sim.top.swap_pending)
                  << " doorbell_ok=" << int(sim.top.doorbell_ok)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec
                  << " cycle=" << sim.cycle << "\n";
        throw std::runtime_error("running-restart: lower restarted seq did not present");
    }
    expectFreshSample("running-restart lower seq", sim, 214);

    std::cout << "ddr_frame_store warm-reset raw: running_arm_restart stale_seq=9 fresh_seq=1"
              << " stale_bank=0 fresh_bank=1 frames=" << sim.top.frames_done
              << " sample_r=214 underruns=" << sim.top.underrun_count
              << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runEqualTokenFallback() {
    Sim sim;
    sim.fillFrame(0, 48);
    sim.ringDoorbell(0, 5);
    sim.resetCore();
    if (!sim.waitCyclesNoFrame(25000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: equal-token fallback fired too early"
                  << " cycle=" << sim.cycle << " frames=" << sim.top.frames_done << "\n";
        std::exit(1);
    }

    sim.fillFrame(0, 212);
    sim.ringDoorbell(0, 5);
    if (!sim.waitForFrame(800000))
        throw std::runtime_error("equal-token fallback did not recover");
    expectFreshSample("equal-token fallback", sim, 212);

    std::cout << "ddr_frame_store warm-reset raw: equal_token_fallback stale_seq=5 fresh_seq=5"
              << " stale_bank=0 fresh_bank=0 no_frame_cycles=25000 frames="
              << sim.top.frames_done << " sample_r=212 underruns=" << sim.top.underrun_count
              << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runLiveValidYuvResetPrimedDoorbell() {
    Sim sim;
    sim.fillFrame(1, 218);
    sim.ringDoorbell(1, 0x68, kDoorbellFormatYuv420p);
    sim.resetCore();
    if (!sim.waitCyclesNoFrame(25000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: live valid YUV reset-primed token"
                  << " presented before fallback window cycle=" << sim.cycle
                  << " frames=" << sim.top.frames_done
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }
    if (sim.top.debug_state == kDebugFormatError) {
        std::cerr << "FAIL ddr_frame_store warm-reset: live valid YUV token raised 0x"
                  << std::hex << int(kDebugFormatError) << std::dec << "\n";
        std::exit(1);
    }
    if (!sim.waitForFrame(800000))
        throw std::runtime_error("live valid YUV reset-primed token did not recover through fallback");
    expectFreshSample("live valid YUV reset-primed token", sim, 218);

    std::cout << "ddr_frame_store warm-reset raw: live_valid_yuv_reset_primed"
              << " doorbell_hi=0xa0000068 bank=1 format=1 seq=0x68"
              << " no_frame_cycles=25000 frame_debug=0x00"
              << " frames=" << sim.top.frames_done << " sample_r=218"
              << " underruns=" << sim.top.underrun_count
              << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runEqualTokenRefreshAfterAccept() {
    Sim sim;
    sim.fillFrame(0, 96);
    sim.resetCore();
    for (int i = 0; i < 3000; ++i)
        sim.tick();
    sim.ringDoorbell(0, 13);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error("equal-token refresh: initial frame did not present");
    expectFreshSample("equal-token refresh initial", sim, 96);

    const int prevFrames = sim.top.frames_done;
    sim.fillFrame(0, 217);
    sim.ringDoorbell(0, 13);
    if (!sim.waitForFrameCountStatic(prevFrames + 1, 800000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: equal-token refresh after accept did not present"
                  << " prev_frames=" << prevFrames << " frames=" << sim.top.frames_done
                  << " has_frame=" << int(sim.top.has_frame)
                  << " swap_pending=" << int(sim.top.swap_pending)
                  << " doorbell_ok=" << int(sim.top.doorbell_ok)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec
                  << " cycle=" << sim.cycle << "\n";
        throw std::runtime_error("equal-token refresh after accept did not present");
    }
    expectFreshSample("equal-token refresh after accept", sim, 217);

    std::cout << "ddr_frame_store warm-reset raw: equal_token_refresh_after_accept"
              << " seq=13 bank=0 prev_frames=" << prevFrames
              << " frames=" << sim.top.frames_done << " sample_r=217 underruns="
              << sim.top.underrun_count << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

bool runSupersessionOverlap(const std::string& label, int triggerToVsyncTicks, bool triggerAfterVsync) {
    Sim sim;
    constexpr uint8_t initialY = 96;
    constexpr uint8_t committedY = 173;
    constexpr uint8_t refreshY = 217;
    sim.fillFrame(0, initialY);
    sim.fillFrame(1, committedY);
    sim.resetCore();
    for (int i = 0; i < 3000; ++i)
        sim.tick();
    sim.ringDoorbell(0, 21);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error(label + ": initial frame did not present");
    expectFreshSample(label + " initial", sim, initialY);

    const int frameBeforePending = sim.top.frames_done;
    sim.triggerStart(1);
    if (!sim.waitForPendingReady(50000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: " << label
                  << " pending frame never reached ready state"
                  << " frames=" << sim.top.frames_done
                  << " pending=" << int(sim.top.swap_pending)
                  << " ready=" << int(sim.top.debug_pending_ready)
                  << " ready_id=" << int(sim.top.debug_pending_ready_id)
                  << " req_id=" << int(sim.top.debug_pending_req_id)
                  << " queued=" << int(sim.top.debug_queued_refresh_valid)
                  << " wait_swap=" << int(sim.top.debug_queued_refresh_wait_swap)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }
    const int oldReqId = sim.top.debug_pending_req_id;
    sim.fillFrame(0, refreshY);

    if (triggerAfterVsync) {
        sim.pulseVsync();
        sim.triggerStart(0);
    } else {
        sim.triggerStart(0);
        for (int i = 0; i < triggerToVsyncTicks; ++i)
            sim.tick();
        sim.pulseVsync();
    }

    if (!sim.waitForFrameCountStatic(frameBeforePending + 1, 2000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: " << label
                  << " committed frame did not present after overlap"
                  << " frames=" << sim.top.frames_done
                  << " pending=" << int(sim.top.swap_pending)
                  << " ready=" << int(sim.top.debug_pending_ready)
                  << " ready_id=" << int(sim.top.debug_pending_ready_id)
                  << " req_id=" << int(sim.top.debug_pending_req_id)
                  << " queued=" << int(sim.top.debug_queued_refresh_valid)
                  << " wait_swap=" << int(sim.top.debug_queued_refresh_wait_swap)
                  << " disp_buf=" << int(sim.top.debug_disp_buf)
                  << " disp_buf_d2=" << int(sim.top.debug_disp_buf_d2)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }

    sim.forceDdrBusy = true;
    expectFreshSample(label + " committed frame preserved", sim, committedY);
    sim.forceDdrBusy = false;

    if (!sim.waitForPendingReady(50000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: " << label
                  << " superseding refresh never reached ready state"
                  << " frames=" << sim.top.frames_done
                  << " pending=" << int(sim.top.swap_pending)
                  << " ready=" << int(sim.top.debug_pending_ready)
                  << " ready_id=" << int(sim.top.debug_pending_ready_id)
                  << " req_id=" << int(sim.top.debug_pending_req_id)
                  << " queued=" << int(sim.top.debug_queued_refresh_valid)
                  << " wait_swap=" << int(sim.top.debug_queued_refresh_wait_swap)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }
    if (sim.top.debug_pending_req_id == oldReqId ||
        sim.top.debug_pending_ready_id != sim.top.debug_pending_req_id) {
        std::cerr << "FAIL ddr_frame_store warm-reset: " << label
                  << " reused stale request readiness identity"
                  << " old_req=" << oldReqId
                  << " new_req=" << int(sim.top.debug_pending_req_id)
                  << " ready_id=" << int(sim.top.debug_pending_ready_id)
                  << " frames=" << sim.top.frames_done
                  << " queued=" << int(sim.top.debug_queued_refresh_valid)
                  << " wait_swap=" << int(sim.top.debug_queued_refresh_wait_swap)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }

    if (!sim.waitForFrameCountStatic(frameBeforePending + 2, 800000)) {
        std::cerr << "FAIL ddr_frame_store warm-reset: " << label
                  << " superseding refresh did not complete"
                  << " frames=" << sim.top.frames_done
                  << " pending=" << int(sim.top.swap_pending)
                  << " ready=" << int(sim.top.debug_pending_ready)
                  << " ready_id=" << int(sim.top.debug_pending_ready_id)
                  << " req_id=" << int(sim.top.debug_pending_req_id)
                  << " queued=" << int(sim.top.debug_queued_refresh_valid)
                  << " wait_swap=" << int(sim.top.debug_queued_refresh_wait_swap)
                  << " debug=0x" << std::hex << int(sim.top.debug_state) << std::dec << "\n";
        std::exit(1);
    }
    expectFreshSample(label + " superseding refresh", sim, refreshY);

    std::cout << "ddr_frame_store warm-reset raw: " << label
              << " old_req=" << oldReqId
              << " new_req=" << int(sim.top.debug_pending_req_id)
              << " ready_id=" << int(sim.top.debug_pending_ready_id)
              << " trigger_to_vsync_ticks=" << triggerToVsyncTicks
              << " trigger_after_vsync=" << int(triggerAfterVsync)
              << " frames=" << sim.top.frames_done
              << " committed_r=" << int(committedY)
              << " refresh_r=" << int(refreshY)
              << " underruns=" << sim.top.underrun_count
              << " cycles=" << sim.cycle << "\n";
    return sim.schedulerProven();
}

void prepareProtocolOverlap(Sim& sim, const std::string& label) {
    sim.protocolLabel = label;
    sim.fillFrame(0, 96);
    sim.fillFrame(1, 173);
    sim.resetCore();
    for (int i = 0; i < 3000; ++i) sim.tick();
    sim.ringDoorbell(0, 31);
    if (!sim.waitForFrame(50000))
        throw std::runtime_error(label + ": initial frame missing");
    expectFreshSample(label + " initial", sim, 96);
    sim.triggerStart(1);
    if (!sim.waitForPendingReady(50000))
        throw std::runtime_error(label + ": announced swap not ready");
}

void runOwnershipCrossing(int period, int phase, bool delayOwner) {
    Sim sim(period, phase);
    const std::string label = delayOwner ? "delayed_owner" : "delayed_pending";
    prepareProtocolOverlap(sim, label);
    sim.watchActiveCache = true;
    sim.top.test_override_disp_sync = delayOwner;
    sim.top.test_disp_sync = sim.top.debug_disp_buf_d2;
    sim.top.test_override_pending_sync = !delayOwner;
    sim.top.test_pending_sync = sim.top.debug_swap_pending_d2;
    sim.pulseVsync();
    for (int i = 0; i < 8; ++i) sim.tick();
    if (sim.top.frames_done != 2 || sim.top.swap_pending)
        throw std::runtime_error(label + ": pending swap did not commit");
    if (delayOwner && sim.top.debug_disp_buf_d2 == sim.top.debug_disp_buf)
        throw std::runtime_error(label + ": owner crossing was not delayed");
    if (!delayOwner && !sim.top.debug_swap_pending_d2)
        throw std::runtime_error(label + ": pending crossing was not delayed");
    sim.fillFrame(0, 217);
    sim.triggerStart(0);
    sim.forceDdrBusy = true;
    for (int i = 0; i < 80; ++i) sim.tick();
    expectFreshSample(label + " under backpressure", sim, 173);
    sim.top.test_override_disp_sync = 0;
    sim.top.test_override_pending_sync = 0;
    for (int i = 0; i < 20; ++i) sim.tick();
    expectFreshSample(label + " after crossing release", sim, 173);
    sim.forceDdrBusy = false;
    if (!sim.waitForPendingReady(50000) || !sim.waitForFrameCountStatic(3, 2000))
        throw std::runtime_error(label + ": refreshed frame missing");
    expectFreshSample(label + " refresh", sim, 217);
    std::cout << "ddr_frame_store protocol: " << label
              << " pixel_period=10 ddr_period=" << period << " ddr_phase=" << phase
              << " frames=" << sim.top.frames_done << " preserved=173 refreshed=217\n";
}

void runIndependentOwnership() {
    runOwnershipCrossing(7, 2, true);
    runOwnershipCrossing(7, 2, false);
    runOwnershipCrossing(13, 4, true);
    runOwnershipCrossing(13, 4, false);
}

void runAcceptedReplacement() {
    Sim sim(7, 1);
    prepareProtocolOverlap(sim, "accepted_replacement");
    sim.triggerStart(0);
    for (int i = 0; i < 20 && !sim.top.debug_queued_refresh_valid; ++i) sim.tick();
    if (!sim.top.debug_queued_refresh_valid)
        throw std::runtime_error("accepted_replacement: no queued predecessor");

    // The external token and bank are posted first; only their synchronized
    // observation is held until the exact dequeue opportunity.
    sim.top.test_override_start_sync = 1;
    sim.top.test_start_sync = sim.top.debug_start_d2;
    sim.top.bank_sel = 1;
    sim.startToggle = !sim.startToggle;
    sim.top.start_req = sim.startToggle;
    sim.replacementPostedAt = sim.ddrEdges;
    for (int i = 0; i < 8; ++i) sim.tick();
    sim.replaceOnRetire = true;
    sim.pulseVsync();
    for (int i = 0; i < 50000 && !sim.replacementObserved; ++i) sim.tick();
    if (!sim.replacementObserved)
        throw std::runtime_error("accepted_replacement: no simultaneous accepted-start/dequeue witness");
    for (int i = 0; i < 8; ++i) sim.tick();
    sim.top.test_override_start_sync = 0;
    if (!sim.waitForPendingReady(50000) || !sim.waitForFrameCountStatic(3, 2000))
        throw std::runtime_error("accepted_replacement: newest request did not present");
    expectFreshSample("accepted_replacement newest bank", sim, 173);
    std::cout << "ddr_frame_store protocol: accepted replacement retained"
              << " frames=" << sim.top.frames_done << " newest_bank=1 sample_r=173\n";
}

bool statusPublishedSince(const Sim& sim, size_t first, uint16_t value) {
    if (sim.statusMailboxes.size() <= first) return false;
    const uint64_t payload = sim.statusMailboxes.back();
    return uint32_t(payload) == kStatusMailboxMagic &&
           uint16_t(payload >> 32) == value && sim.top.debug_osd_captured == value &&
           sim.top.debug_osd_ack_sync == sim.top.debug_osd_request;
}

void awaitStatus(Sim& sim, size_t first, uint16_t value, const std::string& context) {
    for (int i = 0; i < 12000; ++i) {
        sim.tick();
        if (statusPublishedSince(sim, first, value)) return;
    }
    throw std::runtime_error("OSD epoch: stable final status missing " + context +
        " expected=" + std::to_string(value) +
        " captured=" + std::to_string(sim.top.debug_osd_captured) +
        " hold=" + std::to_string(sim.top.debug_osd_hold) +
        " request=" + std::to_string(sim.top.debug_osd_request) +
        " seen=" + std::to_string(sim.top.debug_osd_seen) +
        " accepted_mailboxes=" + std::to_string(sim.statusMailboxes.size() - first));
}

void publishStatus(Sim& sim, uint16_t value, const std::string& context) {
    const size_t first = sim.statusMailboxes.size();
    if (sim.top.status_osd == value)
        throw std::runtime_error("OSD bench attempted unchanged priming value");
    sim.top.status_osd = value;
    awaitStatus(sim, first, value, context);
}

void stopDdrWhenIdle(Sim& sim) {
    for (int i = 0; i < 12000; ++i) {
        sim.tick();
        if ((sim.top.debug_state & 0x0F) == 0 && !sim.top.DDRAM_RD && !sim.top.DDRAM_WE &&
            sim.rdLeft == 0 && sim.rdDelay < 0 && sim.busy == 0) {
            sim.pauseDdrClock = true;
            return;
        }
    }
    throw std::runtime_error("OSD bench could not stop DDR between memory transactions");
}

void resetOsdWhileDdrStopped(Sim& sim, uint16_t a, uint16_t b) {
    const uint64_t stoppedAt = sim.ddrEdges;
    const unsigned oldAck = sim.top.debug_osd_seen;
    sim.top.status_osd = 0;
    sim.top.reset = 1;
    for (int i = 0; i < 8; ++i) {
        sim.top.status_osd = a ^ uint16_t(i + 1);
        sim.tick();
    }
    // A is present on the first released SYS edge, before stale ACK can return.
    sim.top.status_osd = a;
    sim.top.reset = 0;
    for (int i = 0; i < 6; ++i) sim.tick();
    sim.top.status_osd = b;
    for (int i = 0; i < 6; ++i) sim.tick();
    // Intermediate values coalesce; leave exactly B stable after the exchange.
    for (int i = 0; i < 8; ++i) {
        sim.top.status_osd = b ^ (uint16_t(1) << i);
        sim.tick();
    }
    sim.top.status_osd = b;
    for (int i = 0; i < 6; ++i) sim.tick();
    if (sim.ddrEdges != stoppedAt || sim.top.debug_osd_seen != oldAck)
        throw std::runtime_error("OSD bench failed to preserve stopped DDR/old ACK phase");
#ifdef OSD_RESET_EPOCH_CANDIDATE
    if (sim.top.debug_osd_ready || sim.top.debug_osd_hold || sim.top.debug_osd_request)
        throw std::runtime_error("OSD epoch: published before destination reset completion");
#endif
    std::cout << "OSD stopped witness: old_ack=" << oldAck
              << " hold=" << sim.top.debug_osd_hold
              << " request=" << unsigned(sim.top.debug_osd_request)
              << " ack_sync=" << unsigned(sim.top.debug_osd_ack_sync)
              << " final=" << b << "\n";
}

void runOsdResetEpoch(unsigned oldPhase) {
    if (oldPhase > 1) throw std::runtime_error("OSD old ACK phase must be 0 or 1");
    // First two profiles preserve the SYS85/DDR90 edge ratio with different
    // phase. The last is deliberate slow-clock protocol stress, not a build.
    const int profiles[][3] = {{36, 34, 0}, {36, 34, 17}, {10, 37, 11}};
    unsigned scenarios = 0;
    for (const auto& profile : profiles) {
        Sim sim(profile[1], profile[2], profile[0]);
        sim.resetCore();
        for (unsigned round = 0; round < 3; ++round) {
            publishStatus(sim, uint16_t(0x2101 + 4 * round), "prime first ACK");
            if (sim.top.debug_osd_seen != oldPhase)
                publishStatus(sim, uint16_t(0x2102 + 4 * round), "prime selected ACK");
            if (sim.top.debug_osd_seen != oldPhase)
                throw std::runtime_error("OSD bench failed to prime selected old ACK");
            stopDdrWhenIdle(sim);
            const size_t first = sim.statusMailboxes.size();
            const uint16_t a = uint16_t(0x4100 + round);
            const uint16_t b = uint16_t(0x8200 + round);
            resetOsdWhileDdrStopped(sim, a, b);
            if (round == 2) {
                resetOsdWhileDdrStopped(sim, a ^ 0x0010, b ^ 0x0010);
                resetOsdWhileDdrStopped(sim, a, b);
            }
            sim.forceDdrBusy = round != 0;
            sim.pauseDdrClock = false;
            if (round == 1) {
                sim.top.status_osd = a ^ 0x0800;
                sim.tick();
                sim.top.status_osd = b;
                sim.tick();
                sim.top.status_osd = a;
                sim.tick();
                sim.top.status_osd = b;
            }
            if (sim.forceDdrBusy) {
                for (int i = 0; i < 1024; ++i) sim.tick();
                if (sim.statusMailboxes.size() != first)
                    throw std::runtime_error("OSD bench accepted a mailbox during DDR backpressure");
                if (sim.top.debug_osd_captured != b)
                    throw std::runtime_error("OSD epoch: stable final status missing under backpressure");
                sim.forceDdrBusy = false;
            }
            awaitStatus(sim, first, b, "after stopped-DDR reset/restart");
            for (int i = 0; i < 1024; ++i) {
                sim.tick();
                if (!statusPublishedSince(sim, first, b))
                    throw std::runtime_error("OSD epoch: stable final status reverted");
            }
            ++scenarios;
        }
        sim.forceDdrBusy = true;
        const size_t first = sim.statusMailboxes.size();
        for (unsigned i = 0; i < 200; ++i) {
            sim.top.status_osd = uint16_t(0xC000 + i);
            sim.tick();
        }
        sim.top.status_osd = 0xA55A;
        for (int i = 0; i < 1024; ++i) sim.tick();
        if (sim.top.debug_osd_captured != 0xA55A)
            throw std::runtime_error("OSD epoch: running coalescing lost stable final status");
        sim.forceDdrBusy = false;
        awaitStatus(sim, first, 0xA55A, "after running coalescing/backpressure");
        ++scenarios;
    }
    std::cout << "OK OSD epoch: old_ack=" << oldPhase << " scenarios=" << scenarios
              << " actual_DUT=1 captured_status=1 accepted_PLXS_payload=1\n";
}

void run() {
    bool schedulerSeen = false;
    schedulerSeen |= runInitialFrameMailboxPublish();
    schedulerSeen |= runInitialFrameMailboxAbsentWhenDdrBusy();
    runInputMailboxSequence();
    runUnderrunMailboxSnapshot();
    schedulerSeen |= runFreshNoStale();
    schedulerSeen |= runChromaPlaneReadMapping();
    schedulerSeen |= runChromaVerticalStrideMapping();
    schedulerSeen |= runWarmResetChanged(1, 2, 0, 1, expectedRgb(208), "increment");
    schedulerSeen |= runWarmResetChanged(7, 1, 0, 1, expectedRgb(209), "restart_lower_seq");
    schedulerSeen |= runWarmResetChanged(3, 3, 0, 1, expectedRgb(210), "equal_seq_changed_bank");
    schedulerSeen |= runWarmResetChanged(kSeqMask, 0, 0, 1, expectedRgb(211), "seq_wrap");
    schedulerSeen |= runRejectNonYuvDoorbell();
    schedulerSeen |= runRunningArmRestartLower();
    schedulerSeen |= runFrameMailboxStallsWithHungLineRead();
    schedulerSeen |= runEqualTokenFallback();
    schedulerSeen |= runLiveValidYuvResetPrimedDoorbell();
    schedulerSeen |= runEqualTokenRefreshAfterAccept();
    schedulerSeen |= runSupersessionOverlap("supersession_before_pending_vsync", 2, false);
    schedulerSeen |= runSupersessionOverlap("supersession_on_pending_vsync", 0, false);
    schedulerSeen |= runSupersessionOverlap("supersession_after_pending_vsync", 0, true);
    runIndependentOwnership();
    runAcceptedReplacement();
    if (!schedulerSeen) {
        std::cerr << "FAIL ddr_frame_store warm-reset: refill scheduler pipeline not observed\n";
        std::exit(1);
    }
    std::cout << "OK ddr_frame_store warm-reset: stale doorbell ignored until fresh frame; refill scheduler pipelined\n";
}
} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        if (argc == 1)
            run();
        else if (argc == 2 && std::string(argv[1]) == "--picture-cdc")
            runIndependentOwnership();
        else if (argc == 2 && std::string(argv[1]) == "--picture-replacement")
            runAcceptedReplacement();
        else if (argc == 3 && std::string(argv[1]) == "--osd-reset-epoch")
            runOsdResetEpoch(unsigned(std::stoul(argv[2])));
        else
            throw std::runtime_error("unknown warm-reset test selector");
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL ddr_frame_store warm-reset: " << e.what() << "\n";
        return 1;
    }
}
