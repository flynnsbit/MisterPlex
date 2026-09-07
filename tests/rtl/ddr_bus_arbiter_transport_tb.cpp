#include "Vddr_bus_arbiter.h"
#include "verilated.h"

#include <cstdint>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <tuple>

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

struct Command {
    bool read;
    uint32_t address;
    uint64_t data;
    uint8_t burst;
    uint8_t be;
    bool operator==(const Command& other) const {
        return std::tie(read, address, data, burst, be) ==
               std::tie(other.read, other.address, other.data, other.burst, other.be);
    }
};

static uint64_t response(uint32_t address, unsigned beat = 0) {
    return UINT64_C(0xbadc0ffee0000000) ^ (uint64_t(address) << 8) ^ beat;
}

struct Sim {
    Vddr_bus_arbiter d;
    uint64_t time = 0, ddr_cycle = 0;
    uint64_t timing_hash = UINT64_C(14695981039346656037);
    unsigned m1_accepted = 0, m1_issued = 0, m1_reads = 0, m1_received = 0;
    unsigned m0_accepted = 0, m0_received = 0;
    unsigned latency = 11;
    bool zero_latency = false, force_busy = false, busy_pattern = true;
    bool stalled = false;
    Command stalled_command{};
    std::deque<Command> pending_m1;
    std::deque<uint64_t> expected_m1, expected_m0;
    struct Beat { uint64_t due, data; };
    std::deque<Beat> beats;

    Sim() {
        d.clk = d.clk_m1 = 0;
        d.reset = 1;
        d.m1_want = 1;
        d.m0_rd = d.m0_we = d.m1_rd = d.m1_we = 0;
        d.m0_addr = d.m1_addr = 0;
        d.m0_din = d.m1_din = 0;
        d.m0_be = d.m1_be = 0xff;
        d.m0_burstcnt = d.m1_burstcnt = 1;
        d.DDRAM_BUSY = d.DDRAM_DOUT_READY = 0;
        d.DDRAM_DOUT = 0;
        run(520);
        d.reset = 0;
        run(520);
    }

    Command bus_command() const {
        return {bool(d.DDRAM_RD), uint32_t(d.DDRAM_ADDR), uint64_t(d.DDRAM_DIN),
                uint8_t(d.DDRAM_BURSTCNT), uint8_t(d.DDRAM_BE)};
    }

    void record_timing(uint64_t value) {
        timing_hash = (timing_hash ^ value) * UINT64_C(1099511628211);
    }

    void step() {
        ++time;
        const bool rise_ddr = (time % 6 == 3);
        const bool rise_sys = (time % 26 == 13);
        bool delivered = false;
        if (rise_ddr) {
            ++ddr_cycle;
            d.DDRAM_BUSY = force_busy || (busy_pattern && ddr_cycle % 17 < 6);
            delivered = !beats.empty() && beats.front().due <= ddr_cycle;
            d.DDRAM_DOUT_READY = delivered;
            d.DDRAM_DOUT = delivered ? beats.front().data : 0;
        }
        d.eval();
        if (rise_ddr && zero_latency && !delivered && !d.DDRAM_BUSY && d.DDRAM_RD) {
            d.DDRAM_DOUT_READY = 1;
            d.DDRAM_DOUT = response(d.DDRAM_ADDR);
            d.eval();
        }
        if (rise_ddr) {
            record_timing(time);
            record_timing(uint64_t(d.DDRAM_RD) | (uint64_t(d.DDRAM_WE) << 1) |
                          (uint64_t(d.m0_busy) << 2) | (uint64_t(d.m0_dout_ready) << 3));
            if (d.DDRAM_RD || d.DDRAM_WE) {
                record_timing(d.DDRAM_ADDR);
                record_timing(d.DDRAM_DIN);
                record_timing(uint64_t(d.DDRAM_BE) | (uint64_t(d.DDRAM_BURSTCNT) << 8));
            }
            if (d.m0_dout_ready) record_timing(d.m0_dout);
        }
        if (rise_sys) {
            record_timing(time);
            record_timing(uint64_t(d.m1_busy) | (uint64_t(d.m1_dout_ready) << 1));
            if (d.m1_dout_ready) record_timing(d.m1_dout);
        }
        const bool take_m1 = rise_sys && !d.m1_busy && (d.m1_rd || d.m1_we);
        const bool take_m0 = rise_ddr && !d.m0_busy && (d.m0_rd || d.m0_we);
        if (take_m1) {
            pending_m1.push_back({bool(d.m1_rd), uint32_t(d.m1_addr), uint64_t(d.m1_din),
                                  uint8_t(d.m1_burstcnt), uint8_t(d.m1_be)});
            ++m1_accepted;
        }
        if (rise_ddr) {
            const bool command = d.DDRAM_RD || d.DDRAM_WE;
            if (stalled) require(command && bus_command() == stalled_command,
                                 "DDR command changed while BUSY");
            if (command && d.DDRAM_BUSY && !stalled) {
                stalled = true;
                stalled_command = bus_command();
            }
            if (command && !d.DDRAM_BUSY) {
                stalled = false;
                const auto cmd = bus_command();
                if (cmd.address >= 0x10000 && cmd.address < 0x20000) {
                    require(!pending_m1.empty(), "unaccepted/duplicate m1 DDR transaction");
                    require(cmd == pending_m1.front(), "m1 DDR order/payload mismatch");
                    pending_m1.pop_front();
                    ++m1_issued;
                    if (cmd.read) {
                        ++m1_reads;
                        expected_m1.push_back(response(cmd.address));
                    }
                } else {
                    require(take_m0 || d.reset, "unexpected m0 DDR transaction");
                    if (take_m0) ++m0_accepted;
                    if (cmd.read && !d.reset)
                        for (unsigned i = 0; i < cmd.burst; ++i)
                            expected_m0.push_back(response(cmd.address, i));
                }
                if (cmd.read && !zero_latency)
                    for (unsigned i = 0; i < cmd.burst; ++i)
                        beats.push_back({ddr_cycle + latency + i, response(cmd.address, i)});
                if (zero_latency) require(cmd.burst == 1, "zero latency case needs single beat");
            }
            if (d.m0_dout_ready) {
                require(!expected_m0.empty(), "old/unowned response reached m0");
                require(d.m0_dout == expected_m0.front(), "m0 response data/order mismatch");
                expected_m0.pop_front();
                ++m0_received;
            }
            if (delivered) beats.pop_front();
        }
        if (rise_sys && d.m1_dout_ready) {
            require(!expected_m1.empty(), "old/unowned/duplicate response reached m1");
            require(d.m1_dout == expected_m1.front(), "m1 response data/order mismatch");
            expected_m1.pop_front();
            ++m1_received;
        }
        d.clk = time % 6 >= 3;
        d.clk_m1 = time % 26 >= 13;
        d.eval();
        if (take_m1) d.m1_rd = d.m1_we = 0;
        if (take_m0) d.m0_rd = d.m0_we = 0;
    }

    void run(unsigned ticks) {
        while (ticks--) step();
    }

    template<class Predicate> void until(Predicate done, const char* error) {
        for (unsigned i = 0; i < 500000; ++i) {
            if (done()) return;
            step();
        }
        throw std::runtime_error(error);
    }

    void m1(bool read, unsigned seq) {
        require(!d.m1_rd && !d.m1_we, "m1 driver already has a request");
        d.m1_rd = read;
        d.m1_we = !read;
        d.m1_addr = 0x10000 + seq;
        d.m1_din = UINT64_C(0x1234000000000000) | seq;
        d.m1_be = 0x81 | (seq & 0x7e);
    }

    void m0(bool read, unsigned seq, unsigned burst = 1) {
        require(!d.m0_rd && !d.m0_we, "m0 driver already has a request");
        d.m0_rd = read;
        d.m0_we = !read;
        d.m0_addr = 0x20000 + seq;
        d.m0_din = UINT64_C(0x4321000000000000) | seq;
        d.m0_burstcnt = burst;
    }

    void drain() {
        until([&] { return !d.m1_rd && !d.m1_we && !d.m0_rd && !d.m0_we &&
                           pending_m1.empty() && expected_m1.empty() &&
                           expected_m0.empty() && beats.empty(); }, "drain timeout");
        run(260);
        require(m1_accepted == m1_issued, "accepted m1 command lost");
        require(m1_reads == m1_received, "accepted m1 read response lost");
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Sim s;
        for (unsigned i = 0; i < 96; ++i) {
            s.m1(i % 3 != 0, i);
            s.m0(i % 2 != 0, i, i % 2 ? 4 : 1);
            s.until([&] { return !s.d.m1_rd && !s.d.m1_we &&
                                 !s.d.m0_rd && !s.d.m0_we; }, "fairness/acceptance timeout");
        }
        s.drain();

        s.force_busy = true;
        s.m1(true, 200);
        s.until([&] { return !s.d.m1_rd; }, "queued read not accepted");
        s.run(260);
        s.d.reset = 1;
        s.run(130);
        s.force_busy = false;
        s.run(520);
        s.d.reset = 0;
        s.drain();

        s.busy_pattern = false;
        s.latency = 80;
        s.m1(true, 201);
        const auto wanted = s.m1_issued + 1;
        s.until([&] { return s.m1_issued == wanted; }, "in-flight read not issued");
        s.d.reset = 1;
        s.run(780);
        s.d.reset = 0;
        s.drain();

        s.m0(true, 300, 4);
        s.until([&] { return !s.d.m0_rd; }, "m0 read not accepted");
        s.d.reset = 1;
        s.expected_m0.clear();
        s.run(780);
        s.d.reset = 0;
        s.drain();

        s.zero_latency = true;
        s.m1(true, 202);
        s.drain();
        s.m0(true, 301);
        s.drain();
        std::cout << "PASS held-request CDC: m1=" << s.m1_accepted
                  << " reads=" << s.m1_reads << " responses=" << s.m1_received
                  << " m0=" << s.m0_accepted
                  << " ticks=" << s.time << " timing_hash=" << std::hex << s.timing_hash << std::dec
                  << " stalls/reset retirement/fairness/zero-latency\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL held-request CDC: " << e.what() << '\n';
        return 1;
    }
}
