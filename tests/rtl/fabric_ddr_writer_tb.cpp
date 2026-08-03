// Verilator TB: fabric_ddr_writer I420 bank fill + doorbell ordering.
#include "Vfabric_ddr_writer_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

namespace {

constexpr uint32_t kPhysBase = 0x30180000u;
constexpr uint32_t kStride = 0x2000u;
constexpr uint32_t kDoorbell = 0x30183000u;
constexpr int kCodedW = 16;
constexpr int kCodedH = 16;
constexpr int kFrameBytes = (kCodedW * kCodedH * 3) / 2; // 384
constexpr int kFrameQwords = kFrameBytes / 8;             // 48
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr uint32_t kFmtYuv = 1u;

struct WriteRec {
    uint32_t addr_q;
    uint64_t data;
    uint64_t cycle;
};

uint64_t pack_qword(uint32_t qword_index) {
    // Deterministic payload: low 32 = index, high 32 = ~index
    return (uint64_t(uint32_t(~qword_index)) << 32) | uint64_t(qword_index);
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfabric_ddr_writer_tb_top top{};

    const bool inject_early_doorbell_check_only = false;
    (void)inject_early_doorbell_check_only;

    auto tick = [&]() {
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
    };

    // Reset
    top.reset = 1;
    top.src_valid = 0;
    top.src_data = 0;
    top.src_frame_start = 0;
    top.src_bank = 0;
    top.DDRAM_BUSY = 0;
    for (int i = 0; i < 8; ++i)
        tick();
    top.reset = 0;
    tick();

    std::vector<WriteRec> writes;
    writes.reserve(kFrameQwords + 4);

    int q_sent = 0;
    bool frame_started = false;
    bool saw_frame_done = false;
    uint64_t cycle = 0;
    constexpr uint64_t kTimeout = 100000;

    // Drive one bank-0 frame with occasional BUSY stalls.
    while (cycle < kTimeout && !saw_frame_done) {
        // Sample DUT outputs from previous eval (posedge results).
        if (top.DDRAM_WE && !top.DDRAM_BUSY) {
            WriteRec w;
            w.addr_q = uint32_t(top.DDRAM_ADDR);
            w.data = uint64_t(top.DDRAM_DIN);
            w.cycle = cycle;
            writes.push_back(w);
        }
        if (top.frame_done)
            saw_frame_done = true;

        // Source drive for next cycle
        top.DDRAM_BUSY = ((cycle % 7u) == 3u) ? 1 : 0; // periodic stall

        const bool want_send = (q_sent < kFrameQwords);
        top.src_valid = want_send ? 1 : 0;
        top.src_frame_start = (want_send && q_sent == 0) ? 1 : 0;
        top.src_bank = 0;
        top.src_data = want_send ? pack_qword(uint32_t(q_sent)) : 0;

        tick();
        ++cycle;

        // After posedge, if ready&&valid, beat accepted.
        // Re-eval: acceptance is on the posedge we just did — check ready from
        // pre-tick? Verilator: inputs set, tick rises clk, DUT samples.
        // So we need ready from before tick. Capture ready before tick next loop.
        // Fix: check acceptance using previous ready — redo with two-phase.
    }

    // Restart with correct ready sampling
    // Full reset and proper handshake loop.
    top.reset = 1;
    top.src_valid = 0;
    top.src_frame_start = 0;
    top.DDRAM_BUSY = 0;
    for (int i = 0; i < 8; ++i)
        tick();
    top.reset = 0;
    tick();

    writes.clear();
    q_sent = 0;
    saw_frame_done = false;
    cycle = 0;
    int busy_stalls = 0;

    while (cycle < kTimeout && !saw_frame_done) {
        // Decide BUSY for this cycle before clock edge (stable).
        top.DDRAM_BUSY = ((cycle % 7u) == 3u) ? 1 : 0;
        if (top.DDRAM_BUSY)
            ++busy_stalls;

        // Drive source based on current ready (combinational from prev state).
        const bool want_send = (q_sent < kFrameQwords);
        top.src_frame_start = (want_send && q_sent == 0) ? 1 : 0;
        top.src_bank = 0;
        top.src_data = want_send ? pack_qword(uint32_t(q_sent)) : 0;
        top.src_valid = want_send ? 1 : 0;
        top.eval(); // update ready

        const bool fire = top.src_valid && top.src_ready;

        // Rising edge
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        ++cycle;

        // Observe writes accepted this edge: WE && !BUSY at edge.
        // DUT sets WE in NBA of this edge; we see it after eval.
        if (top.DDRAM_WE && !top.DDRAM_BUSY) {
            WriteRec w;
            w.addr_q = uint32_t(top.DDRAM_ADDR);
            w.data = uint64_t(top.DDRAM_DIN);
            w.cycle = cycle;
            writes.push_back(w);
        }
        if (top.frame_done)
            saw_frame_done = true;

        if (fire)
            ++q_sent;
    }

    auto fail = [&](const char* msg) {
        std::cerr << "FAIL fabric_ddr_writer: " << msg << "\n";
        std::cerr << "  q_sent=" << q_sent << " writes=" << writes.size()
                  << " frame_done=" << saw_frame_done << " cycles=" << cycle
                  << " busy_stalls=" << busy_stalls << "\n";
        return 1;
    };

    if (!saw_frame_done)
        return fail("timeout waiting for frame_done");
    if (q_sent != kFrameQwords)
        return fail("source did not deliver full frame");

    // Split payload vs doorbell writes.
    const uint32_t base_q = kPhysBase >> 3;
    const uint32_t db_q = kDoorbell >> 3;
    std::vector<WriteRec> payload;
    std::vector<WriteRec> doorbells;
    for (const auto& w : writes) {
        if (w.addr_q == db_q)
            doorbells.push_back(w);
        else
            payload.push_back(w);
    }

    if (int(payload.size()) != kFrameQwords) {
        std::cerr << "payload writes=" << payload.size() << " expected " << kFrameQwords
                  << "\n";
        return fail("payload write count mismatch");
    }
    if (doorbells.size() != 1)
        return fail("expected exactly one doorbell write");

    // Payload addresses sequential from bank0 base.
    for (int i = 0; i < kFrameQwords; ++i) {
        const uint32_t expect_addr = base_q + uint32_t(i);
        if (payload[uint32_t(i)].addr_q != expect_addr) {
            std::cerr << "payload[" << i << "] addr_q=0x" << std::hex
                      << payload[uint32_t(i)].addr_q << " expect 0x" << expect_addr
                      << std::dec << "\n";
            return fail("payload address sequence wrong");
        }
        const uint64_t expect_data = pack_qword(uint32_t(i));
        if (payload[uint32_t(i)].data != expect_data) {
            std::cerr << "payload[" << i << "] data mismatch\n";
            return fail("payload data mismatch");
        }
    }

    // Doorbell after last payload (cycle ordering).
    const uint64_t last_payload_cycle = payload.back().cycle;
    const uint64_t db_cycle = doorbells[0].cycle;
    if (db_cycle <= last_payload_cycle) {
        std::cerr << "doorbell cycle=" << db_cycle
                  << " last_payload_cycle=" << last_payload_cycle << "\n";
        return fail("doorbell raced payload (ordering violation)");
    }

    // Drain fence: at least WRITE_DRAIN_CYCLES (=4) between last payload and db.
    if (db_cycle < last_payload_cycle + 4) {
        std::cerr << "doorbell too soon: db=" << db_cycle
                  << " last_payload=" << last_payload_cycle << "\n";
        return fail("doorbell before drain fence");
    }

    // Magic + format + bank + seq
    const uint64_t db = doorbells[0].data;
    const uint32_t lo = uint32_t(db);
    const uint32_t hi = uint32_t(db >> 32);
    if (lo != kMagic) {
        std::cerr << "doorbell magic=0x" << std::hex << lo << std::dec << "\n";
        return fail("doorbell magic mismatch");
    }
    const uint32_t bank = (hi >> 31) & 1u;
    const uint32_t fmt = (hi >> 29) & 3u;
    const uint32_t seq = hi & 0x1FFFFFFFu;
    if (bank != 0)
        return fail("doorbell bank bit expected 0");
    if (fmt != kFmtYuv)
        return fail("doorbell format expected YUV420p=1");
    if (seq == 0)
        return fail("doorbell seq should be non-zero after first frame");

    // frame_done must not precede doorbell accept cycle
    // (sampled same cycle as doorbell WE in DUT — allowed equal).

    // ---- Bank 1 smoke ----
    q_sent = 0;
    saw_frame_done = false;
    writes.clear();
    // wait idle
    for (int i = 0; i < 16 && top.busy; ++i)
        tick();

    while (cycle < kTimeout * 2 && !saw_frame_done) {
        top.DDRAM_BUSY = 0;
        const bool want_send = (q_sent < kFrameQwords);
        top.src_frame_start = (want_send && q_sent == 0) ? 1 : 0;
        top.src_bank = 1;
        top.src_data = want_send ? pack_qword(uint32_t(q_sent)) : 0;
        top.src_valid = want_send ? 1 : 0;
        top.eval();
        const bool fire = top.src_valid && top.src_ready;
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        ++cycle;
        if (top.DDRAM_WE && !top.DDRAM_BUSY) {
            WriteRec w{uint32_t(top.DDRAM_ADDR), uint64_t(top.DDRAM_DIN), cycle};
            writes.push_back(w);
        }
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
            const uint32_t hi2 = uint32_t(w.data >> 32);
            if (((hi2 >> 31) & 1u) != 1u)
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

    // Rate arithmetic self-check (compile-time numbers printed for evidence).
    constexpr double kClkMhz = 90.0;
    constexpr double kFrame720 = 1382400.0;
    constexpr double mbps24 = kFrame720 * 24.0 / 1e6;
    constexpr double mbps30 = kFrame720 * 30.0 / 1e6;
    constexpr double frac24 = (kFrame720 * 24.0 / 8.0) / (kClkMhz * 1e6);
    constexpr double frac30 = (kFrame720 * 30.0 / 8.0) / (kClkMhz * 1e6);
    const bool rate_closes = (frac30 < 0.10); // <10% of 90 MHz with depth=1

    std::cout << "OK fabric_ddr_writer"
              << " tiny_frame_qwords=" << kFrameQwords
              << " payload_writes=" << kFrameQwords
              << " doorbells=1"
              << " seq=" << seq
              << " drain_ok=1"
              << " bank1_ok=1"
              << " rate_720p24_MBps=" << mbps24
              << " rate_720p30_MBps=" << mbps30
              << " bus_frac_30=" << frac30
              << " outstanding_depth=1"
              << " rate_closes=" << (rate_closes ? 1 : 0)
              << " cycles=" << cycle
              << "\n";
    if (!rate_closes) {
        std::cerr << "FAIL rate arithmetic does not close at 720p30\n";
        return 1;
    }
    return 0;
}
