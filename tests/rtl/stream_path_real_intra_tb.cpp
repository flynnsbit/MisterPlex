#include "Vstream_path_recon_integration_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int kFrameW = 320;
constexpr int kFrameH = 240;
constexpr int kFramePixels = kFrameW * kFrameH;
constexpr uint16_t kGray128 = static_cast<uint16_t>((16u << 11) | (32u << 5) | 16u);

std::vector<uint8_t> readBytes(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open bitstream: " + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

uint16_t gray565(uint8_t y) {
    return static_cast<uint16_t>(((y >> 3) << 11) | ((y >> 2) << 5) | (y >> 3));
}

std::vector<int> readTopReconY(const std::string& path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("cannot open golden json: " + path);
    const std::string text((std::istreambuf_iterator<char>(in)), {});
    const std::string key = "\"recon_y\"";
    size_t pos = text.find(key);
    if (pos == std::string::npos) throw std::runtime_error("golden json missing top-level recon_y");
    pos = text.find('[', pos);
    if (pos == std::string::npos) throw std::runtime_error("golden json malformed recon_y");
    std::vector<int> out;
    while (pos < text.size() && text[pos] != ']') {
        if ((text[pos] >= '0' && text[pos] <= '9') || text[pos] == '-') {
            char* end = nullptr;
            long v = std::strtol(text.c_str() + pos, &end, 10);
            out.push_back(static_cast<int>(v));
            pos = static_cast<size_t>(end - text.c_str());
        } else {
            ++pos;
        }
    }
    if (out.size() != 256) throw std::runtime_error("golden recon_y length != 256");
    return out;
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
    int framePixels = 0;
    int mb0Captured = 0;
    std::vector<uint16_t> pixels;
    std::vector<uint16_t> mb0;
};

void observe(Vstream_path_recon_integration_tb_top& dut, Result& r, int& wrIndex, bool captureFull, bool captureMb0) {
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
        if (captureFull && wrIndex < kFramePixels) {
            if (r.pixels.size() < static_cast<size_t>(kFramePixels))
                r.pixels.push_back(px);
            r.framePixels = static_cast<int>(r.pixels.size());
        }
        if (wrIndex == 0 && r.firstPixel < 0) r.firstPixel = px;
        if (captureMb0 && x < 16 && y < 16) {
            const int mb0Idx = y * 16 + x;
            if (r.mb0.empty()) r.mb0.assign(256, 0xffff);
            if (r.mb0[mb0Idx] == 0xffff) {
                r.mb0[mb0Idx] = px;
                r.mb0Captured++;
            }
        }
        if (x < 4 && y < 4) {
            r.mb0Samples++;
            if (px != kGray128) r.non128First4x4++;
        }
        wrIndex++;
    }
    r.cycles++;
}

Result run(const std::string& bitstream, bool captureFull, bool captureMb0) {
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
    if (captureFull) r.pixels.reserve(kFramePixels);
    int wrIndex = 0;
    dut.ioctl_download = 1;
    for (uint8_t byte : stream) {
        dut.ioctl_dout = byte;
        dut.ioctl_wr = 1;
        tick(dut); observe(dut, r, wrIndex, captureFull, captureMb0);
        dut.ioctl_wr = 0;
        tick(dut); observe(dut, r, wrIndex, captureFull, captureMb0);
    }
    dut.ioctl_download = 0;

    for (int i = 0; i < 400000; ++i) {
        const bool haveFirst4x4 = r.reconPulses > 0 && r.mb0Samples >= 16;
        const bool haveMb0 = !captureMb0 || r.mb0Captured >= 256;
        const bool haveFrame = !captureFull || r.framePixels >= kFramePixels;
        if (haveFirst4x4 && haveMb0 && haveFrame) break;
        tick(dut); observe(dut, r, wrIndex, captureFull, captureMb0);
    }
    return r;
}
}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc != 2 && argc != 3) {
        std::cerr << "usage: " << argv[0] << " bitstream.264 [mb0_luma_golden.json]\n";
        return 2;
    }
    try {
        const char* dumpPath = std::getenv("STREAM_PATH_DUMP_RGB565");
        const bool captureFull = dumpPath != nullptr && dumpPath[0] != '\0';
        const bool captureMb0 = argc == 3;
        const Result r = run(argv[1], captureFull, captureMb0);
        std::cout << "STREAM_PATH_REAL_INTRA raw"
                  << " residual_pulses=" << r.residualPulses
                  << " recon_pulses=" << r.reconPulses
                  << " recon_sig=0x" << std::hex << (r.reconSig & 0xff)
                  << " recon_dbg=0x" << (r.reconDbg & 0xff)
                  << " first_pixel=0x" << (r.firstPixel & 0xffff)
                  << std::dec
                  << " mb0_first4x4_samples=" << r.mb0Samples
                  << " non128_first4x4=" << r.non128First4x4
                  << " mb0_samples=" << r.mb0Captured
                  << " frame_pixels=" << r.framePixels
                  << " cycles=" << r.cycles << "\n";
        if (argc == 3) {
            const auto golden = readTopReconY(argv[2]);
            int exact = 0;
            for (int i = 0; i < 256; ++i) {
                if (i < static_cast<int>(r.mb0.size()) && r.mb0[i] == gray565(static_cast<uint8_t>(golden[i])))
                    exact++;
            }
            std::cout << "STREAM_PATH_REAL_INTRA mb0_rgb565_exact=" << exact << "/256\n";
        }
        if (captureFull) {
            if (r.framePixels != kFramePixels)
                throw std::runtime_error("full-frame dump requested but frame was incomplete");
            std::ofstream out(dumpPath, std::ios::binary);
            if (!out) throw std::runtime_error(std::string("cannot open dump: ") + dumpPath);
            for (uint16_t px : r.pixels) {
                const char bytes[2] = {static_cast<char>(px & 0xff), static_cast<char>((px >> 8) & 0xff)};
                out.write(bytes, 2);
            }
        }
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
