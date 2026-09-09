#include "Vstream_au_frontend_tb.h"
#include "verilated.h"
#include <cstdint>
#include <initializer_list>
#include <iostream>
#include <stdexcept>

static void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
constexpr unsigned capacity = 1u << TEST_RBSP_ADDR_W;
constexpr unsigned stagingBytes = TEST_STAGING_BYTES;
static uint8_t payloadByte(unsigned i) {
    return 0x40 | (((i * 17) ^ (i >> 8) ^ (i >> 13)) & 0x3f);
}
struct Sim {
    Vstream_au_frontend_tb d;
    unsigned endings = 0;
    void tick() {
        d.clk = 0; d.eval();
        d.clk = 1; d.eval();
        if (d.au_done) ++endings;
        d.clk = 0; d.eval();
    }
    void wait(unsigned n) { while (n--) tick(); }
    void reset() {
        d.reset = 1; d.push = 0; d.byte_in = 0; d.au_end = 0;
        d.rbsp_release = 0; d.read_addr = 0; endings = 0;
        d.scan_hold = 0;
        wait(8); d.reset = 0; wait(4);
    }
    void push(std::initializer_list<uint8_t> data) {
        for (uint8_t byte : data) { d.push = 1; d.byte_in = byte; tick(); }
        d.push = 0;
    }
};
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Sim s;
        s.reset();
        s.push({0,0,1,0x65,0x11,0x22,0x33,0,0,1,0x41,0x55,0x66});
        s.wait(80);
        check(s.d.nalu_count == 1 && s.d.done && s.d.read_data == 0x11,
              "next NAL overwrote owned RBSP");
        const unsigned owned_length = s.d.length;
        check(owned_length == 3, "Annex-B separator zeros leaked into owned RBSP");
        s.wait(200);
        check(s.d.nalu_count == 1 && s.d.length == owned_length && s.d.read_data == 0x11,
              "owned capture changed while decoder held it");
        s.d.rbsp_release = 1;
        s.wait(80);
        check(s.d.nalu_count == 2 && !s.d.done && s.d.length == 2 &&
              s.d.read_data == 0x55, "held next-NAL byte lost/reordered on release");
        s.d.au_end = 1;
        s.wait(20);
        check(s.d.done && s.d.idle && s.endings == 1 && s.d.length == 2,
              "explicit final multi-NAL AU did not close once");
        s.wait(80);
        check(s.endings == 1 && !s.d.overflow, "AU EOF repeated or overflowed");

        s.reset();
        s.push({0,0,1,0x65,0xaa});
        s.wait(300);
        check(!s.d.done && s.endings == 0 && s.d.length == 1,
              "transport gap was mistaken for VCL EOF");
        s.push({0xbb,0xcc});
        s.wait(50);
        s.d.au_end = 1;
        s.wait(20);
        check(s.d.done && s.d.length == 3 && s.endings == 1 &&
              s.d.bytes_seen == 7, "final AU bytes not conserved");
        s.reset();
        s.push({0,0,1,0x65,0x11,0,0,3,0,0,3,1,0x80,0,0,0,1,0x41,0x55});
        s.wait(160);
        const uint8_t expected[] = {0x11,0,0,0,0,1,0x80};
        check(s.d.done && s.d.length == sizeof(expected) && s.d.nalu_count == 1,
              "EPB removal or four-byte delimiter changed RBSP size");
        for (unsigned i = 0; i < sizeof(expected); ++i) {
            s.d.read_addr = i;
            s.wait(3);
            check(s.d.read_data == expected[i], "EPB/payload zero bytes were lost or reordered");
        }
        s.reset();
        s.push({0,0,1,0x67,0x12,0x34,0,0,1,0x68,0x56,0,0,1,0x65,0x80});
        s.wait(100);
        check(s.d.nalu_count == 1, "next NAL escaped parameter-parser ownership");
        s.d.rbsp_release = 1;
        s.wait(100);
        s.d.au_end = 1;
        s.wait(20);
        check(s.d.nalu_count == 3 && s.d.done && s.d.length == 1,
              "parameter-parser release lost the following VCL");
        for (unsigned extra = 0; extra < 2; ++extra) {
            s.reset();
            s.push({0, 0, 1, 0x65});
            for (unsigned i = 0; i < capacity; ++i) s.push({payloadByte(i)});
            s.wait(capacity * 4);
            check(s.d.length == capacity && s.d.reported_length == capacity &&
                  !s.d.done && !s.d.overflow,
                  "RBSP capacity was treated as EOF before the actual boundary");
            for (unsigned i = 0; i < capacity; ++i) {
                s.d.read_addr = i;
                s.wait(3);
                check(s.d.read_data == payloadByte(i), "RBSP read address aliased or byte changed");
            }
            if (extra) {
                s.push({0x66});
                s.wait(40);
                check(s.d.overflow && !s.d.done && s.d.length == capacity &&
                      s.d.reported_length == capacity + 1,
                      "scanner concealed over-capacity RBSP from its consumer");
                for (unsigned i = 0; i < capacity; ++i) s.push({0x77});
                s.wait(capacity * 4);
                check(s.d.reported_length == capacity + 1 && s.d.length == capacity &&
                      s.d.overflow && !s.d.done && s.d.bytes_seen == capacity * 2 + 5,
                      "extended overflow wrapped the length or hid the error");
                check(s.d.read_data == payloadByte(capacity - 1), "overflow overwrote the final RBSP byte");
                s.d.read_addr = 0;
                s.wait(3);
                check(s.d.read_data == payloadByte(0), "overflow overwrote the owned RBSP prefix");
            }
            s.d.au_end = 1;
            s.wait(40);
            check(s.d.done && s.d.idle && s.endings == 1 && s.d.length == capacity &&
                  bool(s.d.overflow) == bool(extra),
                  "capacity-edge EOF or sticky overflow was not preserved");
        }
        s.d.au_end = 0;
        s.d.rbsp_release = 1;
        s.push({0, 0, 1, 0x65, 0x88});
        s.wait(80);
        check(!s.d.done && !s.d.overflow && s.d.length == 1 &&
              s.d.reported_length == 1 && s.d.read_data == 0x88,
              "fresh capture retained overflow, old length or old bytes");
        s.d.au_end = 1;
        s.wait(40);
        check(s.d.done && s.d.idle && s.endings == 2 && !s.d.overflow,
              "fresh capture after overflow did not complete normally");
        s.reset();
        check(!s.d.done && !s.d.overflow && s.d.length == 0 &&
              s.d.reported_length == 0,
              "reset did not clear capacity-edge capture state");
        s.d.scan_hold = 1;
        s.push({0, 0, 1, 0x06});
        for (unsigned i = 0; i < stagingBytes - capacity - 8; ++i)
            s.push({0x55});
        s.push({0, 0, 1, 0x65});
        for (unsigned i = 0; i < capacity; ++i) s.push({payloadByte(i)});
        s.wait(4);
        check(s.d.fifo_full && s.d.fifo_level == stagingBytes &&
              s.d.bytes_seen == 0 && !s.d.done,
              "whole-AU staging overflowed or full occupancy wrapped to zero");
        s.d.scan_hold = 0;
        s.wait(stagingBytes * 4);
        check(s.d.length == capacity && s.d.bytes_seen == stagingBytes &&
              !s.d.done && !s.d.fifo_full && s.d.fifo_level == 0,
              "full staged AU lost bytes or invented EOF");
        s.d.au_end = 1;
        s.wait(40);
        check(s.d.done && s.d.idle && s.endings == 1 && !s.d.overflow,
              "full staged AU failed explicit EOF");
        for (unsigned i = 0; i < capacity; ++i) {
            s.d.read_addr = i;
            s.wait(3);
            check(s.d.read_data == payloadByte(i),
                  "large encoded AU aliased or overwrote its independent 8 KiB VCL");
        }
        std::cout << "PASS AU frontend: held next-NAL byte, owned RBSP, explicit EOF, "
                     "no timeout-based NAL split, separator quarantine, EPB conservation "
                     "and explicit capacity overflow; RBSP=" << capacity
                  << " encoded-staging=" << stagingBytes << "\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL AU frontend: " << e.what() << '\n';
        return 1;
    }
}
