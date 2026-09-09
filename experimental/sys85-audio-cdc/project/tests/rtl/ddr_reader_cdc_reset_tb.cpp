#include "Vddr_reader_cdc_reset_tb.h"
#include "verilated.h"
#include "ddr_bitstream_ring_bfm.hpp"
#include <cstdint>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>

namespace ring = misterplex::ddr_bitstream_ring;
namespace test = misterplex::test;
static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

struct Sim {
    Vddr_reader_cdc_reset_tb dut;
    test::DdrBitstreamRingBfm ddr;
    std::deque<uint64_t> expected_reads;
    struct Write { uint32_t address; uint64_t data; };
    std::deque<Write> expected_writes;
    std::vector<Write> physical_writes;
    std::unordered_map<uint32_t, unsigned> write_counts;
    uint64_t ticks = 0, ddr_cycles = 0;
    unsigned accepted_reads = 0, accepted_writes = 0, returned_reads = 0;
    unsigned reset_responses = 0;
    uint32_t producer = 0;
    bool force_busy = false, hold_response = false, sys_running = true;

    Sim() {
        dut.clk_sys = dut.clk_ddr = 0;
        dut.reset = 1;
        dut.DDRAM_BUSY = dut.DDRAM_DOUT_READY = 0;
        dut.DDRAM_DOUT = 0;
        ddr.publishCtrl(0, true);
        run(1040);
        resume();
    }

    void tick() {
        ++ticks;
        const bool next_sys = sys_running && ticks % 26 >= 13;
        const bool next_ddr = ticks % 6 >= 3;
        const bool rise_sys = next_sys && !dut.clk_sys;
        const bool rise_ddr = next_ddr && !dut.clk_ddr;
        test::DdrBitstreamRingBfm::Transfer transfer;
        if (rise_ddr) {
            if (hold_response && ddr.pending.valid) ddr.pending.delay = 2;
            transfer = ddr.beforePosedge(dut, ++ddr_cycles, force_busy, false, false);
        } else {
            dut.eval();
        }
        if (rise_sys) {
            require(!dut.out_valid && !dut.au_valid, "control-only reset test emitted media");
            require(!dut.wrong_owner_response, "reader response delivered to another mux owner");
            if (!dut.reader_busy && dut.reader_rd) {
                expected_reads.push_back(ddr.load(dut.reader_addr));
                ++accepted_reads;
            }
            if (!dut.reader_busy && dut.reader_we) {
                expected_writes.push_back({dut.reader_addr, dut.reader_data});
                ++accepted_writes;
            }
            if (dut.reader_response) {
                require(!expected_reads.empty(), "duplicate/unowned reader response");
                require(dut.reader_response_data == expected_reads.front(),
                        "reader response data/order changed across CDC/reset");
                expected_reads.pop_front();
                ++returned_reads;
                if (dut.reset) ++reset_responses;
            }
        }
        dut.clk_sys = next_sys;
        dut.clk_ddr = next_ddr;
        dut.eval();
        if (rise_ddr) {
            ddr.afterPosedge();
            if (transfer.write) {
                require(!expected_writes.empty() &&
                        transfer.address == expected_writes.front().address &&
                        transfer.data == expected_writes.front().data &&
                        transfer.byteEnable == 0xff,
                        "accepted reader write lost/reordered/changed across muxes/CDC");
                expected_writes.pop_front();
                physical_writes.push_back({transfer.address, transfer.data});
                ++write_counts[transfer.address];
            }
        }
    }

    void run(unsigned count) { while (count--) tick(); }
    template<class Predicate> void until(Predicate done, const char* failure) {
        for (unsigned i = 0; i < 2600000; ++i) {
            dut.eval();
            if (done()) return;
            tick();
        }
        throw std::runtime_error(failure);
    }
    bool quiet() const {
        return dut.transport_quiet && !ddr.pending.valid && expected_reads.empty() &&
               accepted_reads == ddr.reads && accepted_writes == ddr.writes;
    }
    void resume() {
        const auto previous = write_counts[ring::kStat6Phys >> 3];
        dut.reset = 0;
        until([&] { return write_counts[ring::kStat6Phys >> 3] > previous &&
                           ddr.resetAcknowledged(producer, true); },
              "reader did not recover a fresh reset/epoch status");
        until([&] { return quiet(); }, "reader/mux/CDC ownership failed to quiesce");
    }
    void offerProbe(uint64_t nonce) {
        until([&] { return quiet(); }, "Probe update overlapped an owned transaction");
        ddr.append(producer, test::encodeRingRecord(ring::Event::Probe, nonce,
                                                   mailbox_abi::kFpgaVideoLayoutId));
        ddr.publishCtrl(producer, true);
    }
    void expectProbe(uint64_t nonce) {
        until([&] {
            ring::VideoCapabilities caps;
            return dut.video_nonce == nonce && ddr.capabilitiesFor(nonce, caps) &&
                   caps.max_au_bytes == 8192;
        }, "fresh Probe failed after reset retirement");
    }
    unsigned occurrences(uint32_t address, uint64_t data) const {
        unsigned count = 0;
        for (auto write : physical_writes)
            count += write.address == address && write.data == data;
        return count;
    }
    void finish() {
        until([&] { return quiet(); }, "final transport drain failed");
        dut.reset = 1;
        run(1040);
        require(expected_reads.empty() && expected_writes.empty() &&
                accepted_reads == returned_reads &&
                accepted_reads == ddr.reads && accepted_writes == ddr.writes,
                "accepted command/response conservation failed");
    }
};

static void busyWriteReset() {
    Sim s;
    s.offerProbe(UINT64_C(0x1122334455667788));
    const uint32_t caps_begin = mailbox_abi::kVideoCapsAddr >> 3;
    s.until([&] { return s.dut.reader_we && s.dut.reader_addr >= caps_begin &&
                        s.dut.reader_addr < caps_begin + 8; }, "reader never offered CAPS write");
    s.force_busy = true;
    s.until([&] { return s.dut.command_full && s.dut.reader_we && s.dut.reader_busy; },
            "BUSY did not hold an offered reader write behind the command FIFO");
    const uint32_t address = s.dut.reader_addr;
    const uint64_t data = s.dut.reader_data;
    require(s.dut.DDRAM_WE && s.dut.DDRAM_BUSY && s.accepted_writes > s.ddr.writes,
            "reset case did not include a physically stalled queued write");
    require(s.occurrences(address, data) == 0, "watched write was already issued");
    s.dut.reset = 1;
    for (unsigned i = 0; i < 5200; ++i) {
        s.tick();
        require(s.dut.reader_we && s.dut.reader_busy && s.dut.reader_addr == address &&
                s.dut.reader_data == data, "reader dropped/changed BUSY-owned write during reset");
    }
    s.force_busy = false;
    s.run(5200);
    require(s.dut.reader_we && s.dut.reader_busy && s.dut.reader_addr == address &&
            s.dut.reader_data == data && s.occurrences(address, data) == 0,
            "reset abandoned or spuriously accepted the held reader write");
    require(s.accepted_writes == s.ddr.writes && s.expected_writes.empty(),
            "accepted queued writes failed to drain while reset remained asserted");
    s.resume();
    require(s.occurrences(address, data) == 1 && s.dut.video_nonce == 0,
            "killed CAPS write was lost/repeated or rebound old video nonce");
    s.offerProbe(UINT64_C(0x2233445566778899));
    s.expectProbe(UINT64_C(0x2233445566778899));
    s.finish();
    std::cout << "PASS actual reader CDC: BUSY-held write survives reset and retires once; fresh Probe\n";
}

static void delayedReadReset() {
    Sim s;
    s.hold_response = true;
    s.until([&] { return s.ddr.pending.valid; }, "no accepted DDR read to delay");
    const auto before = s.returned_reads;
    s.dut.reset = 1;
    s.run(26 * 4);
    s.sys_running = false;
    s.run(26 * 4);
    s.hold_response = false;
    s.until([&] { return !s.ddr.pending.valid; }, "DDR read did not return with consumer clock stopped");
    s.run(6 * 20);
    require(s.returned_reads == before, "stopped consumer clock received a response");
    s.sys_running = true;
    s.until([&] { return s.returned_reads == before + 1; },
            "reset-time reader response lost");
    require(s.dut.reset && s.reset_responses == 1 && s.dut.video_nonce == 0,
            "response did not retire to killed reader exactly once during reset");
    s.run(26 * 40);
    require(s.returned_reads == before + 1, "old reader response duplicated after retirement");
    s.resume();
    s.offerProbe(UINT64_C(0x33445566778899aa));
    s.expectProbe(UINT64_C(0x33445566778899aa));
    s.finish();
    std::cout << "PASS actual reader CDC: delayed read survives reset/stopped sys clock, returns once in reset\n";
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        busyWriteReset();
        delayedReadReset();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL reader CDC reset: " << error.what() << '\n';
        return 1;
    }
}
