#include "Vfabric_luma_linebuf_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfabric_luma_linebuf_tb_top top{};
    auto tick = [&]() {
        top.clk = 0; top.eval();
        top.clk = 1; top.eval();
    };
    top.reset = 1;
    top.wr_en = 0; top.rd_en = 0;
    for (int i = 0; i < 4; ++i) tick();
    top.reset = 0; tick();

    // Write full 1280-byte line with pattern addr&0xFF
    for (int a = 0; a < 1280; ++a) {
        top.wr_en = 1;
        top.wr_addr = a;
        top.wr_data = uint8_t(a & 0xFF);
        tick();
    }
    top.wr_en = 0;

    // Read back a few samples + last
    const int samples[] = {0, 1, 127, 639, 1279};
    for (int s : samples) {
        top.rd_en = 1;
        top.rd_addr = s;
        tick();
        if (!top.rd_valid || top.rd_data != uint8_t(s & 0xFF)) {
            std::cerr << "FAIL linebuf addr=" << s << " data=" << int(top.rd_data)
                      << " valid=" << int(top.rd_valid) << "\n";
            return 1;
        }
    }
    // OOB should not assert valid with garbage write
    top.rd_en = 1;
    top.rd_addr = 2000;
    tick();
    if (top.rd_valid) {
        std::cerr << "FAIL linebuf OOB rd_valid\n";
        return 1;
    }
    std::cout << "OK fabric_luma_linebuf LINE_BYTES=1280 m10k_bits=10240 samples=5\n";
    return 0;
}
