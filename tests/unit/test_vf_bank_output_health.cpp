// Inspect packed I420 bank frames produced by a vf delivery experiment.
//
// OBSERVED DEFECT (parent, viewed pixels 2026-08-02):
//   Packaged daemon produced a full GREEN field (U/V ~ 0) with wrapped TREK24
//   when PMS delivered 624x350 into a 624x480 coded bank reader.
//
// Checks (artifact-only, no device):
//   1) total_bytes > 0 and total_bytes % bank_frame_bytes == 0
//      — catches fail-closed (0 bytes) and pipe desync (non-multiple)
//   2) each bank frame: dead_chroma must be false
//      — zero_frac_u/v >= 0.95 with low mean is the green-field class
//        (host/libmisterplex/yuv420p_chroma_health.hpp)
//
// Usage:
//   test_vf_bank_output_health <file.yuv> [bank_w=624] [bank_h=480]
// Exit: 0 OK, 1 size fail, 2 dead chroma, 3 usage/IO
#include "libmisterplex/yuv420p_chroma_health.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    using namespace misterplex;
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <file.yuv> [bank_w] [bank_h]\n", argv[0]);
        return 3;
    }
    const char* path = argv[1];
    const int bw = argc > 2 ? std::atoi(argv[2]) : 624;
    const int bh = argc > 3 ? std::atoi(argv[3]) : 480;
    if (bw <= 0 || bh <= 0 || (bw & 1) || (bh & 1)) {
        std::fprintf(stderr, "VF_BANK_HEALTH_FAIL reason=bad_geometry %dx%d\n", bw, bh);
        return 3;
    }
    const size_t frame_bytes = yuv420pFrameBytesWH(bw, bh);
    if (frame_bytes == 0) {
        std::fprintf(stderr, "VF_BANK_HEALTH_FAIL reason=frame_bytes_zero\n");
        return 3;
    }

    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (!in) {
        std::fprintf(stderr, "VF_BANK_HEALTH_FAIL reason=open_failed path=%s\n", path);
        return 3;
    }
    const auto total = static_cast<size_t>(in.tellg());
    in.seekg(0, std::ios::beg);

    std::printf("VF_BANK_HEALTH path=%s total_bytes=%zu bank=%dx%d frame_bytes=%zu\n", path,
                total, bw, bh, frame_bytes);

    if (total == 0) {
        std::printf("VF_BANK_HEALTH_FAIL reason=zero_total "
                    "(fail-closed: ffmpeg produced no frames — e.g. crop taller than source)\n");
        return 1;
    }
    if (total % frame_bytes != 0) {
        std::printf("VF_BANK_HEALTH_FAIL reason=not_multiple_of_bank total=%zu frame_bytes=%zu "
                    "remainder=%zu "
                    "(fail-open desync class: producer frame size ≠ coded bank)\n",
                    total, frame_bytes, total % frame_bytes);
        return 1;
    }

    const size_t nframes = total / frame_bytes;
    std::vector<uint8_t> frame(frame_bytes);
    for (size_t i = 0; i < nframes; ++i) {
        in.read(reinterpret_cast<char*>(frame.data()),
                static_cast<std::streamsize>(frame_bytes));
        if (!in) {
            std::printf("VF_BANK_HEALTH_FAIL reason=short_read frame=%zu\n", i);
            return 3;
        }
        const auto hth = inspectYuv420pChroma(frame.data(), bw, bh);
        std::printf("VF_BANK_FRAME i=%zu valid=%d dead_chroma=%d mean_u=%.2f mean_v=%.2f "
                    "zero_frac_u=%.4f zero_frac_v=%.4f\n",
                    i, (int)hth.valid, (int)hth.dead_chroma, hth.mean_u, hth.mean_v,
                    hth.zero_frac_u, hth.zero_frac_v);
        if (!hth.valid) {
            std::printf("VF_BANK_HEALTH_FAIL reason=inspect_invalid frame=%zu\n", i);
            return 3;
        }
        // Parent threshold: zero_frac >= 0.95 on both planes is green-field class.
        if (hth.dead_chroma || (hth.zero_frac_u >= 0.95 && hth.zero_frac_v >= 0.95)) {
            std::printf("VF_BANK_HEALTH_FAIL reason=dead_chroma frame=%zu "
                        "zero_frac_u=%.4f zero_frac_v=%.4f "
                        "(green-field class: U/V effectively zeroed)\n",
                        i, hth.zero_frac_u, hth.zero_frac_v);
            return 2;
        }
    }

    std::printf("VF_BANK_HEALTH_OK nframes=%zu frame_bytes=%zu total=%zu\n", nframes, frame_bytes,
                total);
    return 0;
}
