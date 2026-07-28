// Emit the exact I420 payload misterplexd publishes for an idle screen.
//
// This uses the product renderer (host/libmisterplex/idle_screen.hpp) and the
// product DDR geometry (host/libmisterplex/ddr_frame_layout.hpp) so a device
// readback can be compared byte-for-byte against what the ARM believes it
// wrote. Reimplementing the renderer in the checker would only prove the
// reimplementation; this proves the shipped code path.
//
// Usage: gen_idle_frame [--mode logo|black|screensaver] [--phase N] [--out FILE]
//                       [--width W] [--height H]
// Default geometry is plex480pDdrFrameGeometry() coded size (624x480).

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/idle_screen.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace misterplex;

static int usage(const char* argv0) {
    std::fprintf(stderr,
                 "usage: %s [--mode logo|black|screensaver] [--phase N] "
                 "[--width W] [--height H] [--out FILE]\n",
                 argv0);
    return 2;
}

int main(int argc, char** argv) {
    const DdrFrameGeometry g = plex480pDdrFrameGeometry();
    int w = g.coded_width;
    int h = g.coded_height;
    int phase = 0;
    IdleMode mode = IdleMode::Logo;
    std::string out;

    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto next = [&](const char** dst) {
            if (i + 1 >= argc)
                return false;
            *dst = argv[++i];
            return true;
        };
        const char* v = nullptr;
        if (a == "--mode") {
            if (!next(&v))
                return usage(argv[0]);
            const std::string m = v;
            if (m == "logo")
                mode = IdleMode::Logo;
            else if (m == "black")
                mode = IdleMode::Black;
            else if (m == "screensaver")
                mode = IdleMode::Screensaver;
            else
                return usage(argv[0]);
        } else if (a == "--phase") {
            if (!next(&v))
                return usage(argv[0]);
            phase = std::atoi(v);
        } else if (a == "--width") {
            if (!next(&v))
                return usage(argv[0]);
            w = std::atoi(v);
        } else if (a == "--height") {
            if (!next(&v))
                return usage(argv[0]);
            h = std::atoi(v);
        } else if (a == "--out") {
            if (!next(&v))
                return usage(argv[0]);
            out = v;
        } else {
            return usage(argv[0]);
        }
    }

    const size_t bytes = yuv420pFrameBytes(w, h);
    if (bytes == 0) {
        std::fprintf(stderr, "gen_idle_frame: bad geometry %dx%d\n", w, h);
        return 2;
    }
    std::vector<uint8_t> yuv(bytes);
    if (!renderIdleYuv420p(yuv.data(), w, h, mode, phase)) {
        std::fprintf(stderr, "gen_idle_frame: renderIdleYuv420p refused %dx%d\n", w, h);
        return 2;
    }

    FILE* f = out.empty() ? stdout : std::fopen(out.c_str(), "wb");
    if (!f) {
        std::fprintf(stderr, "gen_idle_frame: cannot open %s\n", out.c_str());
        return 2;
    }
    const size_t wrote = std::fwrite(yuv.data(), 1, yuv.size(), f);
    if (!out.empty())
        std::fclose(f);
    if (wrote != yuv.size()) {
        std::fprintf(stderr, "gen_idle_frame: short write %zu/%zu\n", wrote, yuv.size());
        return 2;
    }
    std::fprintf(stderr, "gen_idle_frame: %dx%d mode=%d phase=%d bytes=%zu\n", w, h,
                 static_cast<int>(mode), phase, yuv.size());
    return 0;
}
