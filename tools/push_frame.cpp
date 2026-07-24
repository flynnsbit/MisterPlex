// Push raw RGB565/RGB24/PCM/annex-B to MiSTerPlex via SPI ioctl, or dump core status.
// Usage:
//   push_frame [--index N] [--rgb24 WxH] file
//   push_frame --status
#include "fpga_spi.hpp"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    uint8_t index = 1;
    int rgb24w = 0, rgb24h = 0;
    bool do_status = false;
    const char* path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--index") == 0 && i + 1 < argc)
            index = static_cast<uint8_t>(std::atoi(argv[++i]));
        else if (std::strcmp(argv[i], "--rgb24") == 0 && i + 1 < argc) {
            std::sscanf(argv[++i], "%dx%d", &rgb24w, &rgb24h);
        } else if (std::strcmp(argv[i], "--status") == 0) {
            do_status = true;
        } else if (argv[i][0] != '-')
            path = argv[i];
    }

    misterplex::FpgaSpi spi;
    if (!spi.open()) {
        std::fprintf(stderr, "fpga open: %s\n", spi.lastError().c_str());
        return 1;
    }

    if (do_status) {
        misterplex::FpgaSpi::CoreStatus st;
        if (!spi.readCoreStatus(st)) {
            std::fprintf(stderr, "status: %s\n", spi.lastError().c_str());
            return 1;
        }
        std::printf(
            "status has_frame=%d has_audio=%d has_stream=%d underrun=%d "
            "nalu=%u last_nal=0x%02x fifo_lvl=%u wr_lo=%u bytes_in=%u bytes_seen=%u\n",
            st.has_frame ? 1 : 0, st.has_audio ? 1 : 0, st.has_stream ? 1 : 0,
            st.audio_underrun ? 1 : 0, st.nalu_count, st.last_nal_type,
            st.stream_fifo_level, st.wr_count_lo, st.stream_bytes_in, st.stream_bytes_seen);
        return 0;
    }

    if (!path) {
        std::fprintf(stderr,
                     "usage: push_frame [--index 1] [--rgb24 320x240] file\n"
                     "       push_frame --status\n");
        return 1;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        std::perror(path);
        return 1;
    }
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(in)), {});
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
    // Ensure Force-bars debug is off (status[9]=0) so auto frame present shows
    spi.setStatusBit(9, 0);
    std::printf("pushed %zu bytes index=%u OK (%.1f ms)\n", buf.size(), index, spi.lastPushMs());
    return 0;
}
