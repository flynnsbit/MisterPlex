// Does the frame store's telemetry survive the failure it is meant to report?
//
// Every PLXS/PLXD mailbox word is emitted from one place: the S_IDLE arm of the
// clk_ddr state machine, gated on a specific poll_div phase. poll_div is
// incremented in S_IDLE and nowhere else. The four wait states (S_LINE_ISSUE,
// S_LINE_WAIT, S_POLL_WAIT, S_WRITE_WAIT) have no timeout.
//
// Consequence under test: withholding a single DDRAM read response parks the
// machine outside S_IDLE forever, which freezes poll_div, which silences all
// mailbox publication. The instrument goes dark exactly when the subsystem it
// instruments stops.
//
// Control varies the one thing under test (the read response) and nothing else.
#include "Vddr_frame_store_warm_reset_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <map>
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

struct Mailbox {
    const char* name;
    uint32_t phys;
};

// Mirrors the parameter overrides in ddr_frame_store_warm_reset_tb_top.sv.
// BANK is the PLXD word the fleet poked on hardware and found unchanged.
const Mailbox kMailboxes[] = {
    {"status", 0x3001F100u}, {"input", 0x3001F108u}, {"sdram", 0x3001F110u},
    {"frame", 0x3001F118u},  {"bank_plxd", 0x3001F128u},
};

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

    // The single independent variable: whether DDR read responses come back.
    bool withholdReadResponse = false;

    std::map<std::string, int> mailboxWrites;
    int otherWrites = 0;
    int readsIssued = 0;

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
        for (const Mailbox& mb : kMailboxes)
            mailboxWrites[mb.name] = 0;
    }

    uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
    uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

    void clearCounters() {
        for (const Mailbox& mb : kMailboxes)
            mailboxWrites[mb.name] = 0;
        otherWrites = 0;
        readsIssued = 0;
    }

    int mailboxTotal() const {
        int total = 0;
        for (const auto& kv : mailboxWrites)
            total += kv.second;
        return total;
    }

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

    void classifyWrite(uint32_t addr) {
        for (const Mailbox& mb : kMailboxes) {
            if (addr == (mb.phys >> 3)) {
                ++mailboxWrites[mb.name];
                return;
            }
        }
        ++otherWrites;
    }

    void serviceDdrStart() {
        if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
            ++readsIssued;
            if (!withholdReadResponse) {
                rdAddr = top.DDRAM_ADDR;
                rdLeft = top.DDRAM_BURSTCNT;
                rdIndex = 0;
                rdDelay = 2;
                busy = rdLeft + rdDelay + 1;
            }
        }
        if (top.DDRAM_WE && busy == 0) {
            const uint32_t off = addrOffQ(top.DDRAM_ADDR);
            classifyWrite(top.DDRAM_ADDR);
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

    void sweep(int ticks) {
        for (int i = 0; i < ticks; ++i)
            videoTick();
    }

    bool waitForFirstFrame(int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            videoTick();
            if (top.frames_done >= 1)
                return true;
        }
        return false;
    }
};

void require(bool ok, const char* msg) {
    if (!ok)
        throw std::runtime_error(msg);
}

void report(const char* phase, const Sim& sim) {
    std::cout << "Raw: phase=" << phase << " mailbox_writes_total=" << sim.mailboxTotal();
    for (const auto& kv : sim.mailboxWrites)
        std::cout << " " << kv.first << "=" << kv.second;
    std::cout << " frame_line_writes=" << sim.otherWrites
              << " ddr_reads_issued=" << sim.readsIssued
              << " debug_state=0x" << std::hex << int(sim.top.debug_state) << std::dec
              << " frames_done=" << sim.top.frames_done << " cycle=" << sim.cycle << "\n";
}

int run() {
    // Long enough to cover the 2^18-cycle mailbox heartbeat, so a word that
    // stays silent is silent for a reason other than "the window was short".
    const int kWindow = 70 * kW * kH;

    Sim sim;
    sim.fillFrame(0, 72);
    sim.fillFrame(1, 196);
    sim.resetCore();
    sim.ringDoorbell(0, 101);
    require(sim.waitForFirstFrame(800000), "first doorbell never presented a frame");

    sim.clearCounters();
    sim.sweep(kWindow);
    const int controlTotal = sim.mailboxTotal();
    const int controlReads = sim.readsIssued;
    // Only words this stimulus actually exercises can be scored. The input
    // mailbox needs a host command, which this bench never sends.
    std::vector<std::string> live, dormant;
    for (const auto& kv : sim.mailboxWrites)
        (kv.second > 0 ? live : dormant).push_back(kv.first);
    report("control", sim);
    std::cout << "Raw: words live in control =";
    for (const auto& n : live) std::cout << " " << n;
    std::cout << " | dormant (not scored, no stimulus in this bench) =";
    for (const auto& n : dormant) std::cout << " " << n;
    std::cout << "\n";

    // Anti-vacuity: if the control window publishes nothing, the fault window
    // publishing nothing proves nothing at all.
    require(controlTotal > 0,
            "control window published no mailbox writes; fault comparison would be vacuous");
    require(!live.empty(),
            "no mailbox word published during control; there is nothing for the fault to silence");
    require(controlReads > 0,
            "control window issued no DDR reads; withholding a read response would change nothing");

    // Self-check for this bench: with the fault NOT injected the second window
    // must still publish, otherwise a green/red here would be an artefact of
    // the bench rather than of the withheld response.
    const bool injectFault = std::getenv("TELEMETRY_LIVENESS_NO_FAULT") == nullptr;
    sim.clearCounters();
    sim.withholdReadResponse = injectFault;
    sim.sweep(kWindow);
    int faultTotal = 0;
    for (const auto& n : live)
        faultTotal += sim.mailboxWrites.at(n);
    const int faultReads = sim.readsIssued;
    report(injectFault ? "read_response_withheld" : "selfcheck_no_fault", sim);

    std::cout << "Raw: independent variable varied: DDRAM_DOUT_READY withheld for reads issued"
              << " after the control window; every other stimulus identical.\n";
    std::cout << "Raw: control_mailbox_writes=" << controlTotal
              << " fault_mailbox_writes=" << faultTotal
              << " control_reads=" << controlReads << " fault_reads=" << faultReads << "\n";

    if (faultTotal > 0) {
        std::cout << "OK ddr_frame_store telemetry liveness: "
                  << (injectFault ? "mailbox publication survived a withheld read response"
                                  : "bench self-check, no fault injected, second window still publishes")
                  << " (" << faultTotal << " writes over " << live.size() << " words).\n";
        return 0;
    }

    std::cerr << "FAIL ddr_frame_store telemetry liveness: one withheld DDR read response "
                 "permanently silenced every mailbox word that this bench exercises (control="
              << controlTotal << " over " << live.size() << " words, fault=0). poll_div advances "
                 "only in S_IDLE and the four wait states have no timeout, so the instrument "
                 "goes dark exactly when the frame store stops. Dead mailboxes on hardware "
                 "therefore do NOT imply a dead clk_ddr domain.\n";
    return 1;
}
} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "Scope: ddr_frame_store clk_ddr telemetry liveness; cold reset, one doorbell, "
                 "70-frame control sweep (longer than the 2^18-cycle mailbox heartbeat) then "
                 "an identical sweep with DDR read responses withheld. Counts real DDRAM_WE "
                 "writes to the five mailbox qwords.\n";
    std::cout << "Audit: this measures publication liveness only. It does not check mailbox "
                 "payload correctness, does not model DDR controller behaviour beyond the "
                 "handshake, and cannot distinguish a stalled DDR controller from a stopped "
                 "clk_ddr on real hardware — it shows only that the two are indistinguishable "
                 "through this instrument.\n";
    try {
        return run();
    } catch (const std::exception& e) {
        std::cerr << "FAIL ddr_frame_store telemetry liveness: " << e.what() << "\n";
        return 1;
    }
}
