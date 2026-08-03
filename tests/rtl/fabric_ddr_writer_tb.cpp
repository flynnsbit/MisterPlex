// Verilator TB: fabric_ddr_writer I420 fill + doorbell; pattern source path.
#include "Vfabric_ddr_writer_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

constexpr uint32_t kPhysBase = 0x30180000u;
constexpr uint32_t kStride = 0x2000u;
constexpr uint32_t kDoorbell = 0x30183000u;
constexpr int kCodedW = 16;
constexpr int kCodedH = 16;
constexpr int kFrameBytes = (kCodedW * kCodedH * 3) / 2;
constexpr int kFrameQwords = kFrameBytes / 8;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr uint32_t kFmtYuv = 1u;

struct WriteRec {
    uint32_t addr_q;
    uint64_t data;
    uint64_t cycle;
};

uint64_t pack_qword(uint32_t qword_index) {
    return (uint64_t(uint32_t(~qword_index)) << 32) | uint64_t(qword_index);
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfabric_ddr_writer_tb_top top{};

    auto tick = [&]() {
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
    };

    auto reset_dut = [&]() {
        top.reset = 1;
        top.src_valid = 0;
        top.src_data = 0;
        top.src_frame_start = 0;
        top.src_bank_id = 0;
        top.use_pattern = 0;
        top.pattern_start = 0;
        top.pattern_bank_id = 0;
        top.DDRAM_BUSY = 0;
        for (int i = 0; i < 8; ++i)
            tick();
        top.reset = 0;
        tick();
    };

    auto fail = [&](const char* msg) -> int {
        std::cerr << "FAIL fabric_ddr_writer: " << msg << "\n";
        return 1;
    };

    // ---------- Manual source path (bank0 + bank1) ----------
    reset_dut();
    std::vector<WriteRec> writes;
    int q_sent = 0;
    bool saw_frame_done = false;
    uint64_t cycle = 0;
    constexpr uint64_t kTimeout = 100000;
    int busy_stalls = 0;

    while (cycle < kTimeout && !saw_frame_done) {
        top.DDRAM_BUSY = ((cycle % 7u) == 3u) ? 1 : 0;
        if (top.DDRAM_BUSY)
            ++busy_stalls;
        const bool want_send = (q_sent < kFrameQwords);
        top.src_frame_start = (want_send && q_sent == 0) ? 1 : 0;
        top.src_bank_id = 0;
        top.src_data = want_send ? pack_qword(uint32_t(q_sent)) : 0;
        top.src_valid = want_send ? 1 : 0;
        top.eval();
        const bool fire = top.src_valid && top.src_ready;
        tick();
        ++cycle;
        if (top.DDRAM_WE && !top.DDRAM_BUSY) {
            writes.push_back({uint32_t(top.DDRAM_ADDR), uint64_t(top.DDRAM_DIN), cycle});
        }
        if (top.frame_done)
            saw_frame_done = true;
        if (fire)
            ++q_sent;
    }

    if (!saw_frame_done)
        return fail("timeout waiting for frame_done");
    if (q_sent != kFrameQwords)
        return fail("source did not deliver full frame");

    const uint32_t base_q = kPhysBase >> 3;
    const uint32_t db_q = kDoorbell >> 3;
    std::vector<WriteRec> payload, doorbells;
    for (const auto& w : writes) {
        if (w.addr_q == db_q)
            doorbells.push_back(w);
        else
            payload.push_back(w);
    }
    if (int(payload.size()) != kFrameQwords)
        return fail("payload write count mismatch");
    if (doorbells.size() != 1)
        return fail("expected exactly one doorbell write");

    for (int i = 0; i < kFrameQwords; ++i) {
        if (payload[uint32_t(i)].addr_q != base_q + uint32_t(i))
            return fail("payload address sequence wrong");
        if (payload[uint32_t(i)].data != pack_qword(uint32_t(i)))
            return fail("payload data mismatch");
    }

    const uint64_t last_payload_cycle = payload.back().cycle;
    const uint64_t db_cycle = doorbells[0].cycle;
    if (db_cycle <= last_payload_cycle)
        return fail("doorbell raced payload (ordering violation)");
    if (db_cycle < last_payload_cycle + 4)
        return fail("doorbell before drain fence");

    const uint64_t db = doorbells[0].data;
    const uint32_t lo = uint32_t(db);
    const uint32_t hi = uint32_t(db >> 32);
    if (lo != kMagic)
        return fail("doorbell magic mismatch");
    if (((hi >> 31) & 1u) != 0)
        return fail("doorbell bank bit expected 0");
    if (((hi >> 29) & 3u) != kFmtYuv)
        return fail("doorbell format expected YUV420p=1");
    const uint32_t seq = hi & 0x1FFFFFFFu;
    if (seq == 0)
        return fail("doorbell seq should be non-zero");

    // Bank 1
    q_sent = 0;
    saw_frame_done = false;
    writes.clear();
    for (int i = 0; i < 16 && top.busy; ++i)
        tick();
    while (cycle < kTimeout * 2 && !saw_frame_done) {
        top.DDRAM_BUSY = 0;
        const bool want_send = (q_sent < kFrameQwords);
        top.src_frame_start = (want_send && q_sent == 0) ? 1 : 0;
        top.src_bank_id = 1;
        top.src_data = want_send ? pack_qword(uint32_t(q_sent)) : 0;
        top.src_valid = want_send ? 1 : 0;
        top.eval();
        const bool fire = top.src_valid && top.src_ready;
        tick();
        ++cycle;
        if (top.DDRAM_WE && !top.DDRAM_BUSY)
            writes.push_back({uint32_t(top.DDRAM_ADDR), uint64_t(top.DDRAM_DIN), cycle});
        if (top.frame_done)
            saw_frame_done = true;
        if (fire)
            ++q_sent;
    }
    if (!saw_frame_done)
        return fail("bank1 timeout");
    const uint32_t bank1_base_q = (kPhysBase + kStride) >> 3;
    int b1_payload = 0;
    bool b1_db = false;
    for (const auto& w : writes) {
        if (w.addr_q == db_q) {
            b1_db = true;
            if (((uint32_t(w.data >> 32) >> 31) & 1u) != 1u)
                return fail("bank1 doorbell bank bit expected 1");
        } else {
            if (w.addr_q != bank1_base_q + uint32_t(b1_payload))
                return fail("bank1 payload address wrong");
            ++b1_payload;
        }
    }
    if (b1_payload != kFrameQwords)
        return fail("bank1 payload count wrong");
    if (!b1_db)
        return fail("bank1 missing doorbell");

    // ---------- Pattern source path (zero manual pixels) ----------
    reset_dut();
    top.use_pattern = 1;
    top.pattern_bank_id = 0;
    top.pattern_start = 1;
    tick();
    top.pattern_start = 0;
    writes.clear();
    saw_frame_done = false;
    cycle = 0;
    while (cycle < kTimeout && !saw_frame_done) {
        top.DDRAM_BUSY = ((cycle % 5u) == 2u) ? 1 : 0;
        tick();
        ++cycle;
        if (top.DDRAM_WE && !top.DDRAM_BUSY)
            writes.push_back({uint32_t(top.DDRAM_ADDR), uint64_t(top.DDRAM_DIN), cycle});
        if (top.frame_done)
            saw_frame_done = true;
    }
    if (!saw_frame_done)
        return fail("pattern path timeout");
    payload.clear();
    doorbells.clear();
    for (const auto& w : writes) {
        if (w.addr_q == db_q)
            doorbells.push_back(w);
        else
            payload.push_back(w);
    }
    if (int(payload.size()) != kFrameQwords)
        return fail("pattern payload count mismatch");
    if (doorbells.size() != 1)
        return fail("pattern expected one doorbell");
    // Y plane first qword: bytes 0..7 = 0..7
    if (payload[0].data != 0x0706050403020100ull)
        return fail("pattern Y qword0 mismatch");
    // First chroma qword after Y_QWORDS = (16*16)/8 = 32
    if (payload[32].data != 0x8080808080808080ull)
        return fail("pattern U qword mismatch");
    if (doorbells[0].cycle <= payload.back().cycle)
        return fail("pattern doorbell raced payload");

    constexpr double kClkMhz = 90.0;
    constexpr double kFrame720 = 1382400.0;
    constexpr double mbps24 = kFrame720 * 24.0 / 1e6;
    constexpr double mbps30 = kFrame720 * 30.0 / 1e6;
    constexpr double frac30 = (kFrame720 * 30.0 / 8.0) / (kClkMhz * 1e6);
    const bool rate_closes = (frac30 < 0.10);

    // Parent-verified reserved window headroom (not a device call — constant check)
    constexpr uint32_t kResStart = 0x1FF00000u;
    constexpr uint32_t kResEnd = 0x40000000u;
    constexpr uint32_t kOptCBase = 0x30180000u;
    constexpr uint32_t kOptCDb = 0x3047F000u;
    constexpr uint32_t kOptCEnd = 0x30480000u;
    const bool iomem_ok = (kOptCBase >= kResStart && kOptCEnd <= kResEnd &&
                           kOptCDb >= kOptCBase && kOptCDb < kOptCEnd);
    constexpr uint32_t kTripleMap = 3u * 0x00180000u;
    constexpr uint32_t kTripleEnd = kOptCBase + kTripleMap;
    const bool triple_fits = (kTripleEnd <= kResEnd);

    std::cout << "OK fabric_ddr_writer"
              << " tiny_frame_qwords=" << kFrameQwords
              << " manual_ok=1 pattern_ok=1"
              << " drain_ok=1 bank1_ok=1"
              << " seq=" << seq
              << " rate_720p24_MBps=" << mbps24
              << " rate_720p30_MBps=" << mbps30
              << " bus_frac_30=" << frac30
              << " outstanding_depth=1"
              << " rate_closes=" << (rate_closes ? 1 : 0)
              << " optionc_iomem_parent_verified=" << (iomem_ok ? 1 : 0)
              << " triple_buffer_map_fits=" << (triple_fits ? 1 : 0)
              << " triple_map_bytes=0x" << std::hex << kTripleMap << std::dec
              << " busy_stalls=" << busy_stalls
              << "\n";
    if (!rate_closes)
        return fail("rate arithmetic does not close at 720p30");
    if (!iomem_ok)
        return fail("Option-C not inside parent-verified reserved window");
    if (!triple_fits)
        return fail("triple-buffer map does not fit reserved window");
    return 0;
}
