#include "Vstream_path_recon_integration_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int kFrameW = 320;
constexpr uint16_t kGray128 = static_cast<uint16_t>((16u << 11) | (32u << 5) | 16u);

std::vector<uint8_t> readBytes(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open bitstream: " + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

void tick(Vstream_path_recon_integration_tb_top& dut) {
    dut.clk = 0; dut.eval();
    dut.clk = 1; dut.eval();
}

struct Result {
    int residualPulses = 0;
    int reconPulses = 0;
    int non128First4x4 = 0;
    int mb0Samples = 0;
    int firstPixel = -1;
    int reconSig = -1;
    int reconDbg = -1;
    int cycles = 0;
};

void observe(Vstream_path_recon_integration_tb_top& dut, Result& r, int& wrIndex) {
    if (dut.residual_place_pulse) r.residualPulses++;
    if (dut.recon_valid) {
        r.reconPulses++;
        if (r.reconSig < 0) {
            r.reconSig = static_cast<uint8_t>(dut.recon_sig);
            r.reconDbg = static_cast<uint8_t>(dut.recon_dbg);
        }
    }
    if (dut.fs_wr_reset_o) wrIndex = 0;
    if (dut.fs_wr_en_o) {
        const int x = wrIndex % kFrameW;
        const int y = wrIndex / kFrameW;
        const uint16_t px = static_cast<uint16_t>(dut.fs_wr_pixel_o);
        if (wrIndex == 0 && r.firstPixel < 0) r.firstPixel = px;
        if (x < 4 && y < 4) {
            r.mb0Samples++;
            if (px != kGray128) r.non128First4x4++;
        }
        wrIndex++;
    }
    r.cycles++;
}

Result run(const std::string& bitstream) {
    auto base = readBytes(bitstream);
    std::vector<uint8_t> stream = base;
    stream.insert(stream.end(), base.begin(), base.end());

    Vstream_path_recon_integration_tb_top dut;
    dut.clk = 0;
    dut.reset = 1;
    dut.ioctl_download = 0;
    dut.ioctl_wr = 0;
    dut.ioctl_dout = 0;
    dut.enable = 1;
    dut.flush = 0;
    tick(dut); tick(dut);
    dut.reset = 0;
    tick(dut);

    Result r;
    int wrIndex = 0;
    dut.ioctl_download = 1;
    for (uint8_t byte : stream) {
        dut.ioctl_dout = byte;
        dut.ioctl_wr = 1;
        tick(dut); observe(dut, r, wrIndex);
        dut.ioctl_wr = 0;
        tick(dut); observe(dut, r, wrIndex);
    }
    dut.ioctl_download = 0;

    for (int i = 0; i < 200000 && (r.reconPulses == 0 || r.mb0Samples < 16); ++i) {
        tick(dut); observe(dut, r, wrIndex);
    }
    return r;
}
}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc != 2) {
        std::cerr << "usage: " << argv[0] << " bitstream.264\n";
        return 2;
    }
    try {
        const Result r = run(argv[1]);
        std::cout << "STREAM_PATH_REAL_INTRA raw"
                  << " residual_pulses=" << r.residualPulses
                  << " recon_pulses=" << r.reconPulses
                  << " recon_sig=0x" << std::hex << (r.reconSig & 0xff)
                  << " recon_dbg=0x" << (r.reconDbg & 0xff)
                  << " first_pixel=0x" << (r.firstPixel & 0xffff)
                  << std::dec
                  << " mb0_first4x4_samples=" << r.mb0Samples
                  << " non128_first4x4=" << r.non128First4x4
                  << " cycles=" << r.cycles << "\n";
        if (r.residualPulses < 1) {
            std::cerr << "FAIL real-intra gate: residual_place_pulse was never observed\n";
            return 1;
        }
        if (r.reconPulses < 1) {
            std::cerr << "FAIL real-intra gate: recon_valid was never observed\n";
            return 1;
        }
        if (r.mb0Samples < 16) {
            std::cerr << "FAIL real-intra gate: did not observe all 16 displayed first-4x4 pixels\n";
            return 1;
        }
        if (r.non128First4x4 == 0) {
            std::cerr << "FAIL real-intra gate: displayed first 4x4 stayed at placeholder gray 128\n";
            return 1;
        }
        std::cout << "OK real-intra gate: displayed first 4x4 contains decoded non-128 pixels\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "ERROR real-intra gate: " << e.what() << "\n";
        return 2;
    }
}
