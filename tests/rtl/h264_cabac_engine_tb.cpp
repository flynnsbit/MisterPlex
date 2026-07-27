#include "Vh264_cabac_engine_tb_top.h"
#include "verilated.h"

#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

struct Op {
    char kind;
    int state_in;
    int bin;
    int state_out;
    int32_t low;
    int range;
    int byte_pos;
};

static uint8_t hexbyte(char hi, char lo) {
    auto val = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        return 0;
    };
    return static_cast<uint8_t>((val(hi) << 4) | val(lo));
}

static void tick(Vh264_cabac_engine_tb_top& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc != 2) {
        std::cerr << "usage: " << argv[0] << " build/cabac_trace.log\n";
        return 2;
    }

    std::ifstream in(argv[1]);
    if (!in) {
        std::cerr << "failed to open trace: " << argv[1] << "\n";
        return 2;
    }

    std::regex init_re(R"(CABAC_TRACE_INIT low=(-?\d+) range=(\d+) bytes=(\d+) data=([0-9a-fA-F]*))");
    std::regex bin_re(R"(CABAC_TRACE_BIN kind=([RBS]) state_in=(-?\d+) bin=(\d+) state_out=(-?\d+) low=(-?\d+) range=(\d+) byte_pos=(-?\d+))");
    std::regex term_re(R"(CABAC_TRACE_BIN kind=(T) state_in=(-?\d+) bin=(\d+) state_out=(-?\d+) low=(-?\d+) range=(\d+) byte_pos=(-?\d+))");

    int32_t init_low = 0;
    int init_range = 0;
    std::vector<uint8_t> bytes;
    std::vector<Op> ops;
    bool saw_init = false;
    std::string line;
    while (std::getline(in, line)) {
        std::smatch m;
        if (!saw_init && std::regex_search(line, m, init_re)) {
            init_low = static_cast<int32_t>(std::stol(m[1].str()));
            init_range = std::stoi(m[2].str());
            std::string data = m[4].str();
            for (size_t i = 0; i + 1 < data.size(); i += 2)
                bytes.push_back(hexbyte(data[i], data[i + 1]));
            saw_init = true;
            continue;
        }
        if (line.find("CABAC_PROBE_SLICE") != std::string::npos && !ops.empty())
            break;
        if (std::regex_search(line, m, bin_re) || std::regex_search(line, m, term_re)) {
            Op op{};
            op.kind = m[1].str()[0];
            op.state_in = std::stoi(m[2].str());
            op.bin = std::stoi(m[3].str());
            op.state_out = std::stoi(m[4].str());
            op.low = static_cast<int32_t>(std::stol(m[5].str()));
            op.range = std::stoi(m[6].str());
            op.byte_pos = std::stoi(m[7].str());
            ops.push_back(op);
        }
    }

    if (!saw_init || ops.empty()) {
        std::cerr << "trace missing CABAC_TRACE_INIT or CABAC_TRACE_BIN rows\n";
        return 2;
    }

    Vh264_cabac_engine_tb_top dut;
    dut.clk = 0;
    dut.reset = 1;
    dut.load = 0;
    dut.valid = 0;
    dut.refill_data = 0;
    tick(dut);

    dut.reset = 0;
    dut.load = 1;
    dut.load_low = static_cast<uint32_t>(init_low);
    dut.load_range = init_range;
    tick(dut);
    dut.load = 0;

    int failures = 0;
    uint64_t cycles = 0;
    for (size_t i = 0; i < ops.size(); ++i) {
        const Op& op = ops[i];
        uint16_t addr = dut.refill_addr;
        uint8_t b0 = (addr < bytes.size()) ? bytes[addr] : 0;
        uint8_t b1 = (addr + 1 < bytes.size()) ? bytes[addr + 1] : 0;
        dut.refill_data = (static_cast<uint16_t>(b0) << 8) | b1;
        dut.mode = (op.kind == 'R') ? 0 : (op.kind == 'B') ? 1 : (op.kind == 'S') ? 2 : 3;
        dut.state_in = op.state_in < 0 ? 0 : op.state_in;
        dut.valid = 1;
        tick(dut);
        ++cycles;

        bool bad = false;
        if (!dut.out_valid) bad = true;
        if (dut.bin != op.bin) bad = true;
        if (op.kind == 'R' && dut.state_out != op.state_out) bad = true;
        if (static_cast<int32_t>(dut.low_dbg) != op.low) bad = true;
        if (dut.range_dbg != op.range) bad = true;
        if (static_cast<int>(dut.byte_pos_dbg) != op.byte_pos) bad = true;
        if (bad) {
            std::cerr << "mismatch op " << i << " kind=" << op.kind
                      << " got bin=" << int(dut.bin) << " state=" << int(dut.state_out)
                      << " low=" << static_cast<int32_t>(dut.low_dbg)
                      << " range=" << int(dut.range_dbg)
                      << " byte_pos=" << int(dut.byte_pos_dbg)
                      << " expected bin=" << op.bin << " state=" << op.state_out
                      << " low=" << op.low << " range=" << op.range
                      << " byte_pos=" << op.byte_pos << "\n";
            if (++failures >= 8) break;
        }
    }
    dut.valid = 0;
    tick(dut);

    if (failures) {
        std::cerr << "H264 CABAC engine RTL trace check FAILED: " << failures << " mismatches\n";
        return 1;
    }

    double bpc = static_cast<double>(ops.size()) / static_cast<double>(cycles);
    std::cout << "H264 CABAC engine Verilator PASS: decoded " << ops.size()
              << " real FFmpeg-traced CABAC bins in " << cycles
              << " issue cycles; bins_per_clock=" << bpc
              << " trace_bytes=" << bytes.size() << "\n";
    return 0;
}
