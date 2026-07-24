// Push a raw RGB565 LE frame (or RGB24) to MiSTerPlex frame_store via SPI ioctl.
// Usage: push_frame [--index N] [--rgb24 WxH] file
#include "fpga_spi.hpp"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    uint8_t index = 1;
    int rgb24w = 0, rgb24h = 0;
    const char* path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--index") == 0 && i + 1 < argc)
            index = static_cast<uint8_t>(std::atoi(argv[++i]));
        else if (std::strcmp(argv[i], "--rgb24") == 0 && i + 1 < argc) {
            std::sscanf(argv[++i], "%dx%d", &rgb24w, &rgb24h);
        } else if (argv[i][0] != '-')
            path = argv[i];
    }
    if (!path) {
        std::fprintf(stderr, "usage: push_frame [--index 1] [--rgb24 320x240] file.rgb565\n");
        return 1;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        std::perror(path);
        return 1;
    }
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(in)), {});
    misterplex::FpgaSpi spi;
    if (!spi.open()) {
        std::fprintf(stderr, "fpga open: %s\n", spi.lastError().c_str());
        return 1;
    }
    bool ok = false;
    if (rgb24w > 0 && rgb24h > 0) {
        if (buf.size() < static_cast<size_t>(rgb24w * rgb24h * 3)) {
            std::fprintf(stderr, "file too small for %dx%d RGB24\n", rgb24w, rgb24h);
            return 1;
        }
        ok = spi.sendRgb24Frame(buf.data(), rgb24w, rgb24h, index);
    } else {
        ok = spi.sendFileTx(buf.data(), buf.size(), index);
    }
    if (!ok) {
        std::fprintf(stderr, "push failed: %s\n", spi.lastError().c_str());
        return 1;
    }
    std::printf("pushed %zu bytes index=%u OK\n", buf.size(), index);
    return 0;
}
