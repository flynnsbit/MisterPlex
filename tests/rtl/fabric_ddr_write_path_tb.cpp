#include "Vfabric_ddr_write_path_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <vector>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfabric_ddr_write_path_tb_top top{};
    auto tick = [&]() {
        top.clk = 0; top.eval();
        top.clk = 1; top.eval();
    };
    top.reset = 1; top.start = 0; top.bank_id = 0; top.DDRAM_BUSY = 0;
    for (int i = 0; i < 8; ++i) tick();
    top.reset = 0; tick();
    top.start = 1; tick();
    top.start = 0;

    constexpr int kQ = 48;
    constexpr uint32_t kDb = 0x30183000u >> 3;
    int payload = 0, db = 0;
    uint64_t last_pay = 0, db_cyc = 0, cyc = 0;
    bool done = false;
    while (cyc < 100000 && !done) {
        top.DDRAM_BUSY = ((cyc % 6) == 1) ? 1 : 0;
        tick();
        ++cyc;
        if (top.DDRAM_WE && !top.DDRAM_BUSY) {
            if (uint32_t(top.DDRAM_ADDR) == kDb) {
                ++db; db_cyc = cyc;
            } else {
                ++payload; last_pay = cyc;
            }
        }
        if (top.frame_done) done = true;
    }
    if (!done || payload != kQ || db != 1 || db_cyc <= last_pay) {
        std::cerr << "FAIL write_path done=" << done << " pay=" << payload
                  << " db=" << db << "\n";
        return 1;
    }
    std::cout << "OK fabric_ddr_write_path pattern→writer qwords=" << kQ
              << " doorbell_after_payload=1\n";
    return 0;
}
